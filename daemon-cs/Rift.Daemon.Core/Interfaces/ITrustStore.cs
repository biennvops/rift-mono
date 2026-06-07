using System;
using System.Collections.Generic;

namespace Rift.Daemon.Core.Interfaces;

public enum TrustState
{
    Discovered,
    PairingPending,
    Trusted,
    Blocked,
    Revoked
}

public class PeerIdentity
{
    public string DeviceId { get; init; } = string.Empty;
    public byte[]? Ed25519PublicKey { get; set; }
    public TrustState State { get; set; }

    public string? EcdsaCertificateFingerprint { get; set; }
    public DateTimeOffset LastStateTransitionAt { get; set; }

    /// <summary>
    /// Evidence needed to reject the identity later if revoked.
    /// </summary>
    public string? RevocationEvidence { get; set; }
}

public interface ITrustStore
{
    /// <summary>
    /// Saves or updates a peer in the local database.
    /// </summary>
    void SavePeer(PeerIdentity peer);

    /// <summary>
    /// Retrieves a peer by their Device ID.
    /// </summary>
    PeerIdentity? GetPeer(string deviceId);

    /// <summary>
    /// Gets all peers currently tracked by the trust store.
    /// </summary>
    IEnumerable<PeerIdentity> GetAllPeers();

    /// <summary>
    /// Attempts to update the state of a peer ensuring a valid state machine transition.
    /// </summary>
    bool TryTransition(string deviceId, TrustState newState);

    /// <summary>
    /// Rejects future connection attempts and retains negative-trust evidence.
    /// </summary>
    void RevokePeer(string deviceId, string revocationEvidence);
}
