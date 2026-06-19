using System.Text;
using System.Text.Json;
using Microsoft.Data.Sqlite;
using Microsoft.Extensions.Logging.Abstractions;
using Rift.Daemon.Core;
using Rift.Daemon.Core.Cryptography;
using Rift.Daemon.Core.Data;
using Rift.Daemon.Core.Interfaces;

namespace Rift.Daemon.Tests.Core;

public sealed class PairingProtocolCoordinatorTests : IDisposable
{
    private readonly string _databasePath;
    private readonly DatabaseContext _databaseContext;
    private readonly SqliteTrustStore _trustStore;
    private readonly SqliteSecurityEventLog _securityEventLog;
    private readonly IdentityManager _identityManager;
    private readonly FakeTransport _transport;
    private readonly FakeDiscoveryService _discoveryService;
    private readonly DiscoveryCoordinator _discoveryCoordinator;
    private readonly PairingProtocolCoordinator _coordinator;

    public PairingProtocolCoordinatorTests()
    {
        _databasePath = Path.Combine(Path.GetTempPath(), $"rift-pairing-protocol-{Guid.NewGuid():N}.db");
        _databaseContext = new DatabaseContext(_databasePath);
        _databaseContext.Initialize();
        _trustStore = new SqliteTrustStore(_databaseContext);
        _securityEventLog = new SqliteSecurityEventLog(_databaseContext);
        _identityManager = new IdentityManager(new SqliteLocalIdentityStore(_databaseContext));
        _transport = new FakeTransport();
        _discoveryService = new FakeDiscoveryService();
        _discoveryCoordinator = new DiscoveryCoordinator(_discoveryService, _trustStore);
        _coordinator = new PairingProtocolCoordinator(
            _transport,
            _discoveryCoordinator,
            _trustStore,
            _identityManager,
            _securityEventLog,
            NullLogger<PairingProtocolCoordinator>.Instance);
    }

    [Fact]
    public void NotifyLocalPairingStarted_ConnectsAndSendsPairingStart()
    {
        _discoveryCoordinator.StartDiscovery();
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer-start",
            Ed25519PublicKey = new byte[32],
            State = TrustState.Discovered,
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });
        _discoveryService.EmitPeerDiscovered(new PeerDiscoveredEventArgs(
            deviceIdHint: "rift-peer-start",
            instanceName: "inst-1",
            host: "192.168.1.50",
            port: 9140,
            minVersion: "0.1-draft",
            maxVersion: "0.1-draft",
            txtRecord: new Dictionary<string, string> { ["did"] = "rift-peer-start" },
            remoteEndPoint: null));

        _coordinator.NotifyLocalPairingStarted("rift-peer-start");

        Assert.Contains(_transport.ConnectionAttempts, attempt => attempt.Host == "192.168.1.50" && attempt.Port == 9140);
        Assert.Contains(_transport.SentMessages, sent => sent.PeerDeviceId == "rift-peer-start" && sent.Type == "pairing.start");
    }

    [Fact]
    public async Task HandleMessageAsync_PairingStart_TransitionsPeerToPairingPending()
    {
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer-inbound",
            Ed25519PublicKey = new byte[32],
            State = TrustState.Discovered,
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });

        await _coordinator.HandleMessageAsync("rift-peer-inbound", CreateEnvelope("rift-peer-inbound", "pairing.start", new { expiresInMs = 120000 }), CancellationToken.None);

        var peer = _trustStore.GetPeer("rift-peer-inbound");
        Assert.Equal(TrustState.PairingPending, peer!.State);
    }

    [Fact]
    public async Task HandleMessageAsync_PairingComplete_WithLocalApproval_TransitionsTrusted()
    {
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer-complete",
            Ed25519PublicKey = new byte[32],
            State = TrustState.PairingPending,
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });

        _coordinator.NotifyLocalPairingApproved("rift-peer-complete");
        await _coordinator.HandleMessageAsync("rift-peer-complete", CreateEnvelope("rift-peer-complete", "pairing.complete", new
        {
            trustedDeviceId = "rift-peer-complete",
            persistedAt = DateTimeOffset.UtcNow.ToString("O")
        }), CancellationToken.None);

        var peer = _trustStore.GetPeer("rift-peer-complete");
        Assert.Equal(TrustState.Trusted, peer!.State);
    }

    public void Dispose()
    {
        SqliteConnection.ClearAllPools();
        if (File.Exists(_databasePath))
        {
            File.Delete(_databasePath);
        }
    }

    private static ReadOnlyMemory<byte> CreateEnvelope(string sourceDeviceId, string type, object payload)
    {
        var bytes = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(new
        {
            rift = "0.1-draft",
            type,
            messageId = Guid.NewGuid().ToString("D"),
            sourceDeviceId,
            payload
        }));
        return bytes;
    }

    private sealed class FakeDiscoveryService : IDiscoveryService
    {
        public event EventHandler<PeerDiscoveredEventArgs>? PeerDiscovered;

        public void StartAdvertising(string deviceId, string minVersion, string maxVersion) { }

        public void StopAdvertising() { }

        public void StartDiscovery() { }

        public void StopDiscovery() { }

        public void EmitPeerDiscovered(PeerDiscoveredEventArgs args) => PeerDiscovered?.Invoke(this, args);
    }

    private sealed class FakeTransport : ITransport
    {
        public event EventHandler<MessageReceivedEventArgs>? MessageReceived;
        public event EventHandler<SessionStateChangedEventArgs>? SessionStateChanged;

        public List<(string Host, int Port)> ConnectionAttempts { get; } = [];

        public List<(string PeerDeviceId, string Type)> SentMessages { get; } = [];

        public Task StartListeningAsync(CancellationToken cancellationToken) => Task.CompletedTask;

        public Task ConnectToPeerAsync(string host, int port, CancellationToken cancellationToken)
        {
            ConnectionAttempts.Add((host, port));
            return Task.CompletedTask;
        }

        public Task SendAsync(string peerDeviceId, ReadOnlyMemory<byte> frameBody, CancellationToken cancellationToken)
        {
            using var document = JsonDocument.Parse(frameBody);
            var type = document.RootElement.GetProperty("type").GetString() ?? string.Empty;
            SentMessages.Add((peerDeviceId, type));
            return Task.CompletedTask;
        }

        public Task DisconnectPeerAsync(string peerDeviceId, CancellationToken cancellationToken) => Task.CompletedTask;
    }
}
