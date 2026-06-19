using System.Text;
using System.Text.Json;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Data.Sqlite;
using Rift.Daemon.Core;
using Rift.Daemon.Core.Cryptography;
using Rift.Daemon.Core.Data;
using Rift.Daemon.Core.Interfaces;

namespace Rift.Daemon.Tests.Core;

public sealed class ProtocolMessageRouterTests : IDisposable
{
    private readonly string _databasePath;
    private readonly DatabaseContext _databaseContext;
    private readonly SqliteTrustStore _trustStore;
    private readonly SqliteSecurityEventLog _securityEventLog;
    private readonly IdentityManager _identityManager;
    private readonly PresenceService _presenceService;
    private readonly PairingProtocolCoordinator _pairingCoordinator;
    private readonly ClipboardService _clipboardService;
    private readonly ProtocolMessageRouter _router;

    public ProtocolMessageRouterTests()
    {
        _databasePath = Path.Combine(Path.GetTempPath(), $"rift-router-{Guid.NewGuid():N}.db");
        _databaseContext = new DatabaseContext(_databasePath);
        _databaseContext.Initialize();
        _trustStore = new SqliteTrustStore(_databaseContext);
        _securityEventLog = new SqliteSecurityEventLog(_databaseContext);
        _identityManager = new IdentityManager(new SqliteLocalIdentityStore(_databaseContext));
        _presenceService = new PresenceService();
        var discoveryCoordinator = new DiscoveryCoordinator(new FakeDiscoveryService(), _trustStore);
        _clipboardService = new ClipboardService(new FakeTransport(), _trustStore, _presenceService, _identityManager, _securityEventLog, NullLogger<ClipboardService>.Instance);
        _pairingCoordinator = new PairingProtocolCoordinator(
            new FakeTransport(),
            discoveryCoordinator,
            _trustStore,
            _identityManager,
            _securityEventLog,
            NullLogger<PairingProtocolCoordinator>.Instance);
        _router = new ProtocolMessageRouter(_pairingCoordinator, _presenceService, _clipboardService);
    }

    [Fact]
    public async Task HandleMessageAsync_PresenceUpdate_UpdatesPresenceState()
    {
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer-presence",
            Ed25519PublicKey = new byte[32],
            State = TrustState.Trusted,
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });

        await _router.HandleMessageAsync("rift-peer-presence", CreateEnvelope("rift-peer-presence", "presence.update", new
        {
            status = "online",
            lastSeenAt = "2026-06-18T11:00:00Z",
            capabilities = new[] { "presence.basic", "security.event_log" }
        }), CancellationToken.None);

        var presence = _presenceService.GetPeerPresence("rift-peer-presence");
        Assert.NotNull(presence);
        Assert.Equal("online", presence!.Status);
        Assert.Equal("2026-06-18T11:00:00Z", presence.LastSeenAt);
        Assert.Contains("presence.basic", presence.Capabilities);
    }

    [Fact]
    public async Task HandleMessageAsync_ClipboardOffer_UsesAuthenticatedSessionIdentity()
    {
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer-clipboard",
            Ed25519PublicKey = new byte[32],
            State = TrustState.Trusted,
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });
        _presenceService.UpdatePeerPresence("rift-peer-clipboard", "online", null, ["clipboard.offer_fetch"]);

        var ex = await Assert.ThrowsAsync<ClipboardFailureException>(() => _router.HandleMessageAsync("rift-peer-clipboard", CreateEnvelope("rift-peer-clipboard", "clipboard.offer", new
        {
            offerId = "offer-identity-check",
            contentType = "text/plain",
            byteSize = 5,
            sha256 = "hash",
            expiresInMs = 120000,
            sourceDeviceId = "rift-spoofed",
            requiredCapability = "clipboard.offer_fetch",
            offerSequence = 1
        }), CancellationToken.None));

        Assert.Equal("Unauthorized", ex.FailureReason);
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
        return Encoding.UTF8.GetBytes(JsonSerializer.Serialize(new
        {
            rift = "0.1-draft",
            type,
            messageId = Guid.NewGuid().ToString("D"),
            sourceDeviceId,
            payload
        }));
    }

    private sealed class FakeDiscoveryService : IDiscoveryService
    {
        public event EventHandler<PeerDiscoveredEventArgs>? PeerDiscovered;

        public void StartAdvertising(string deviceId, string minVersion, string maxVersion) { }

        public void StopAdvertising() { }

        public void StartDiscovery() { }

        public void StopDiscovery() { }
    }

    private sealed class FakeTransport : ITransport
    {
        public event EventHandler<MessageReceivedEventArgs>? MessageReceived;
        public event EventHandler<SessionStateChangedEventArgs>? SessionStateChanged;

        public Task StartListeningAsync(CancellationToken cancellationToken) => Task.CompletedTask;

        public Task ConnectToPeerAsync(string host, int port, CancellationToken cancellationToken) => Task.CompletedTask;

        public Task SendAsync(string peerDeviceId, ReadOnlyMemory<byte> frameBody, CancellationToken cancellationToken) => Task.CompletedTask;

        public Task DisconnectPeerAsync(string peerDeviceId, CancellationToken cancellationToken) => Task.CompletedTask;
    }
}
