using Microsoft.Data.Sqlite;
using System.Text.Json;
using Rift.Daemon.Core.Interfaces;

namespace Rift.Daemon.Core.Data;

public sealed class SqliteTrustStore(DatabaseContext databaseContext) : ITrustStore
{
    public void SavePeer(PeerIdentity peer)
    {
        ArgumentNullException.ThrowIfNull(peer);

        using var connection = databaseContext.CreateOpenConnection();
        using var command = connection.CreateCommand();
        command.CommandText =
            """
            INSERT INTO Peers (DeviceId, Ed25519PublicKey, State, CertificateFingerprint, LastTransition, RevocationEvidence, TrustedEndpointsJson)
            VALUES ($deviceId, $publicKey, $state, $fingerprint, $lastTransition, $revocationEvidence, $trustedEndpointsJson)
            ON CONFLICT(DeviceId) DO UPDATE SET
                Ed25519PublicKey = excluded.Ed25519PublicKey,
                State = excluded.State,
                CertificateFingerprint = excluded.CertificateFingerprint,
                LastTransition = excluded.LastTransition,
                RevocationEvidence = excluded.RevocationEvidence,
                TrustedEndpointsJson = excluded.TrustedEndpointsJson;
            """;
        BindPeer(command, peer);
        command.ExecuteNonQuery();
    }

    public PeerIdentity? GetPeer(string deviceId)
    {
        using var connection = databaseContext.CreateOpenConnection();
        using var command = connection.CreateCommand();
        command.CommandText =
            """
            SELECT DeviceId, Ed25519PublicKey, State, CertificateFingerprint, LastTransition, RevocationEvidence, TrustedEndpointsJson
            FROM Peers
            WHERE DeviceId = $deviceId;
            """;
        command.Parameters.AddWithValue("$deviceId", deviceId);

        using var reader = command.ExecuteReader();
        if (!reader.Read())
        {
            return null;
        }

        return ReadPeer(reader);
    }

    public IEnumerable<PeerIdentity> GetAllPeers()
    {
        using var connection = databaseContext.CreateOpenConnection();
        using var command = connection.CreateCommand();
        command.CommandText =
            """
            SELECT DeviceId, Ed25519PublicKey, State, CertificateFingerprint, LastTransition, RevocationEvidence, TrustedEndpointsJson
            FROM Peers
            ORDER BY DeviceId;
            """;

        var peers = new List<PeerIdentity>();
        using var reader = command.ExecuteReader();
        while (reader.Read())
        {
            peers.Add(ReadPeer(reader));
        }

        return peers;
    }

    public bool TryTransition(string deviceId, TrustState newState)
    {
        using var connection = databaseContext.CreateOpenConnection();
        using var transaction = connection.BeginTransaction();
        using var select = connection.CreateCommand();
        select.Transaction = transaction;
        select.CommandText =
            """
            SELECT DeviceId, Ed25519PublicKey, State, CertificateFingerprint, LastTransition, RevocationEvidence, TrustedEndpointsJson
            FROM Peers
            WHERE DeviceId = $deviceId;
            """;
        select.Parameters.AddWithValue("$deviceId", deviceId);

        PeerIdentity? peer;
        using (var reader = select.ExecuteReader())
        {
            if (!reader.Read())
            {
                return false;
            }

            peer = ReadPeer(reader);
        }

        if (!IsValidTransition(peer.State, newState))
        {
            return false;
        }

        peer.State = newState;
        peer.LastStateTransitionAt = DateTimeOffset.UtcNow;
        if (newState != TrustState.Revoked)
        {
            peer.RevocationEvidence = null;
        }

        using var update = connection.CreateCommand();
        update.Transaction = transaction;
        update.CommandText =
            """
            UPDATE Peers
            SET State = $state,
                LastTransition = $lastTransition,
                RevocationEvidence = $revocationEvidence,
                CertificateFingerprint = $fingerprint,
                Ed25519PublicKey = $publicKey,
                TrustedEndpointsJson = $trustedEndpointsJson
            WHERE DeviceId = $deviceId;
            """;
        BindPeer(update, peer);
        update.ExecuteNonQuery();

        transaction.Commit();
        return true;
    }

    public void RevokePeer(string deviceId, string revocationEvidence)
    {
        using var connection = databaseContext.CreateOpenConnection();
        using var transaction = connection.BeginTransaction();
        using var select = connection.CreateCommand();
        select.Transaction = transaction;
        select.CommandText =
            """
            SELECT DeviceId, Ed25519PublicKey, State, CertificateFingerprint, LastTransition, RevocationEvidence, TrustedEndpointsJson
            FROM Peers
            WHERE DeviceId = $deviceId;
            """;
        select.Parameters.AddWithValue("$deviceId", deviceId);

        PeerIdentity? peer;
        using (var reader = select.ExecuteReader())
        {
            if (!reader.Read())
            {
                throw new InvalidOperationException($"Peer '{deviceId}' was not found.");
            }

            peer = ReadPeer(reader);
        }

        peer.State = TrustState.Revoked;
        peer.RevocationEvidence = revocationEvidence;
        peer.LastStateTransitionAt = DateTimeOffset.UtcNow;

        using var update = connection.CreateCommand();
        update.Transaction = transaction;
        update.CommandText =
            """
            UPDATE Peers
            SET State = $state,
                LastTransition = $lastTransition,
                RevocationEvidence = $revocationEvidence,
                CertificateFingerprint = $fingerprint,
                Ed25519PublicKey = $publicKey,
                TrustedEndpointsJson = $trustedEndpointsJson
            WHERE DeviceId = $deviceId;
            """;
        BindPeer(update, peer);
        update.ExecuteNonQuery();

        transaction.Commit();
    }

    private static bool IsValidTransition(TrustState currentState, TrustState newState)
    {
        return (currentState, newState) switch
        {
            (TrustState.Discovered, TrustState.PairingPending) => true,
            (TrustState.PairingPending, TrustState.Trusted) => true,
            (TrustState.PairingPending, TrustState.Discovered) => true,
            (TrustState.Trusted, TrustState.Blocked) => true,
            (TrustState.Trusted, TrustState.Revoked) => true,
            (TrustState.Blocked, TrustState.Discovered) => true,
            (TrustState.Revoked, TrustState.Discovered) => true,
            _ when currentState == newState => true,
            _ => false
        };
    }

    private static PeerIdentity ReadPeer(SqliteDataReader reader)
    {
        return new PeerIdentity
        {
            DeviceId = (string)reader["DeviceId"],
            Ed25519PublicKey = reader["Ed25519PublicKey"] is DBNull ? null : (byte[])reader["Ed25519PublicKey"],
            State = Enum.Parse<TrustState>((string)reader["State"]),
            EcdsaCertificateFingerprint = reader["CertificateFingerprint"] as string,
            LastStateTransitionAt = DateTimeOffset.Parse((string)reader["LastTransition"]),
            RevocationEvidence = reader["RevocationEvidence"] as string,
            TrustedEndpoints = DeserializeTrustedEndpoints(reader["TrustedEndpointsJson"] as string)
        };
    }

    private static void BindPeer(SqliteCommand command, PeerIdentity peer)
    {
        command.Parameters.AddWithValue("$deviceId", peer.DeviceId);
        command.Parameters.AddWithValue("$publicKey", (object?)peer.Ed25519PublicKey ?? DBNull.Value);
        command.Parameters.AddWithValue("$state", peer.State.ToString());
        command.Parameters.AddWithValue("$fingerprint", (object?)peer.EcdsaCertificateFingerprint ?? DBNull.Value);
        command.Parameters.AddWithValue("$lastTransition", peer.LastStateTransitionAt.ToString("O"));
        command.Parameters.AddWithValue("$revocationEvidence", (object?)peer.RevocationEvidence ?? DBNull.Value);
        command.Parameters.AddWithValue(
            "$trustedEndpointsJson",
            peer.TrustedEndpoints.Count == 0
                ? DBNull.Value
                : JsonSerializer.Serialize(peer.TrustedEndpoints));
    }

    private static IReadOnlyList<TrustedPeerEndpoint> DeserializeTrustedEndpoints(string? rawJson)
    {
        if (string.IsNullOrWhiteSpace(rawJson))
        {
            return [];
        }

        return JsonSerializer.Deserialize<List<TrustedPeerEndpoint>>(rawJson) ?? [];
    }
}
