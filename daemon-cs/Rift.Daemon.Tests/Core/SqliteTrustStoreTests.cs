using Rift.Daemon.Core.Data;
using Rift.Daemon.Core.Interfaces;
using Microsoft.Data.Sqlite;

namespace Rift.Daemon.Tests.Core;

public sealed class SqliteTrustStoreTests : IDisposable
{
    private readonly string _databasePath;
    private readonly DatabaseContext _databaseContext;
    private readonly SqliteTrustStore _trustStore;

    public SqliteTrustStoreTests()
    {
        _databasePath = Path.Combine(Path.GetTempPath(), $"rift-trust-{Guid.NewGuid():N}.db");
        _databaseContext = new DatabaseContext(_databasePath);
        _databaseContext.Initialize();
        _trustStore = new SqliteTrustStore(_databaseContext);
    }

    [Fact]
    public void TryTransition_AllowsProtocolStateMachineAndRejectsInvalidSkips()
    {
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer-a",
            Ed25519PublicKey = new byte[32],
            State = TrustState.Discovered,
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });

        Assert.True(_trustStore.TryTransition("rift-peer-a", TrustState.PairingPending));
        Assert.True(_trustStore.TryTransition("rift-peer-a", TrustState.Trusted));
        Assert.True(_trustStore.TryTransition("rift-peer-a", TrustState.Blocked));
        Assert.True(_trustStore.TryTransition("rift-peer-a", TrustState.Discovered));
        Assert.False(_trustStore.TryTransition("rift-peer-a", TrustState.Trusted));
    }

    [Fact]
    public void RevokePeer_PreservesNegativeTrustEvidence()
    {
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer-b",
            Ed25519PublicKey = new byte[32],
            State = TrustState.Trusted,
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });

        _trustStore.RevokePeer("rift-peer-b", "user-request");

        var peer = _trustStore.GetPeer("rift-peer-b");
        Assert.NotNull(peer);
        Assert.Equal(TrustState.Revoked, peer!.State);
        Assert.Equal("user-request", peer.RevocationEvidence);
    }

    [Fact]
    public void TryTransition_FromRevokedToDiscovered_ClearsRevocationEvidence()
    {
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer-c",
            Ed25519PublicKey = new byte[32],
            State = TrustState.Trusted,
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });

        _trustStore.RevokePeer("rift-peer-c", "user-request");

        Assert.True(_trustStore.TryTransition("rift-peer-c", TrustState.Discovered));

        var peer = _trustStore.GetPeer("rift-peer-c");
        Assert.NotNull(peer);
        Assert.Equal(TrustState.Discovered, peer!.State);
        Assert.Null(peer.RevocationEvidence);
    }

    public void Dispose()
    {
        SqliteConnection.ClearAllPools();
        if (File.Exists(_databasePath))
        {
            File.Delete(_databasePath);
        }
    }
}
