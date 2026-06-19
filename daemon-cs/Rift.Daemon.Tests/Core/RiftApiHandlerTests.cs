using System.Text;
using System.Text.Json;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Data.Sqlite;
using Rift.Daemon.Core;
using Rift.Daemon.Core.Cryptography;
using Rift.Daemon.Core.Data;
using Rift.Daemon.Core.Interfaces;
using StreamJsonRpc;

namespace Rift.Daemon.Tests.Core;

public sealed class RiftApiHandlerTests : IDisposable
{
    private static readonly TimeSpan FetchResponseTimeout = TimeSpan.FromMilliseconds(75);
    private readonly string _databasePath;
    private readonly DatabaseContext _databaseContext;
    private readonly SqliteTrustStore _trustStore;
    private readonly SqliteSecurityEventLog _securityEventLog;
    private readonly IdentityManager _identityManager;
    private readonly FakeDiscoveryService _discoveryService;
    private readonly PresenceService _presenceService;
    private readonly FakeTransport _transport;
    private readonly ClipboardService _clipboardService;
    private readonly RiftApiHandler _handler;

    public RiftApiHandlerTests()
    {
        _databasePath = Path.Combine(Path.GetTempPath(), $"rift-api-{Guid.NewGuid():N}.db");
        _databaseContext = new DatabaseContext(_databasePath);
        _databaseContext.Initialize();
        _trustStore = new SqliteTrustStore(_databaseContext);
        _securityEventLog = new SqliteSecurityEventLog(_databaseContext);
        _identityManager = new IdentityManager(new SqliteLocalIdentityStore(_databaseContext));
        _discoveryService = new FakeDiscoveryService();
        _presenceService = new PresenceService();
        _transport = new FakeTransport();
        var discoveryCoordinator = new DiscoveryCoordinator(_discoveryService, _trustStore);
        var daemonInfoService = new DaemonInfoService(_identityManager, _securityEventLog, _trustStore, discoveryCoordinator, _presenceService);
        _clipboardService = new ClipboardService(_transport, _trustStore, _presenceService, _identityManager, _securityEventLog, NullLogger<ClipboardService>.Instance, FetchResponseTimeout);
        var pairingService = new PairingService(
            _trustStore,
            _identityManager,
            _securityEventLog,
            pairingProtocolCoordinator: null,
            logger: NullLogger<PairingService>.Instance);
        _handler = new RiftApiHandler(daemonInfoService, discoveryCoordinator, _clipboardService, pairingService);
    }

    [Fact]
    public async Task GetDeviceInfoAsync_ReturnsStableLocalIdentityMetadata()
    {
        var result = await _handler.GetDeviceInfoAsync();

        Assert.Equal(_identityManager.GetDeviceId(), result.DeviceId);
        Assert.Equal(_identityManager.GetFingerprint(), result.Fingerprint);
        Assert.Equal("riftd-cs/0.1.0", result.ImplementationId);
        Assert.Equal("0.1-draft", result.ProtocolVersion);
        Assert.Contains(result.Capabilities, capability => capability.Name == "security.event_log");
    }

    [Fact]
    public async Task StartDiscoveryAsync_StartsCoordinatorBackedDiscovery()
    {
        var result = await _handler.StartDiscoveryAsync();

        Assert.True(result.Started);
        Assert.True(_discoveryService.IsDiscovering);
    }

    [Fact]
    public async Task ListDiscoveredPeersAsync_ReturnsPeersWithDeviceIdHints()
    {
        await _handler.StartDiscoveryAsync();
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-discovered-peer",
            Ed25519PublicKey = new byte[32],
            State = TrustState.Trusted,
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });

        _discoveryService.EmitPeerDiscovered(new PeerDiscoveredEventArgs(
            deviceIdHint: "rift-discovered-peer",
            instanceName: "instance-1",
            host: "192.168.1.42",
            port: 9140,
            minVersion: "0.1-draft",
            maxVersion: "0.1-draft",
            txtRecord: new Dictionary<string, string>
            {
                ["minV"] = "0.1-draft",
                ["maxV"] = "0.1-draft",
                ["did"] = "rift-discovered-peer"
            },
            remoteEndPoint: null));

        var result = await _handler.ListDiscoveredPeersAsync();

        Assert.Contains(result.Peers, peer =>
            peer.DeviceId == "rift-discovered-peer" &&
            peer.Address == "192.168.1.42" &&
            peer.Port == 9140 &&
            peer.TrustState == "trusted");
    }

    [Fact]
    public async Task StartPairingAsync_TransitionsPeerToPairingPending()
    {
        var peerPublicKey = Convert.FromHexString("d75a980182b10ab7d54bfed3c964073a0ee172f3daa3f4a18446b0b8d183f8e3");
        var deviceId = IdentityManager.DeriveDeviceId(peerPublicKey);
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = deviceId,
            Ed25519PublicKey = peerPublicKey,
            State = TrustState.Discovered,
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });

        var result = await _handler.StartPairingAsync(deviceId);
        var storedPeer = _trustStore.GetPeer(deviceId);

        Assert.Equal(_identityManager.GetFingerprint(), result.Fingerprint);
        Assert.Equal(IdentityManager.DeriveFingerprint(peerPublicKey), result.PeerFingerprint);
        Assert.Equal(TrustState.PairingPending, storedPeer!.State);
    }

    [Fact]
    public async Task ListTrustedPeersAsync_ReturnsPersistedTrustStoreEntries()
    {
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer-listed",
            Ed25519PublicKey = new byte[32],
            State = TrustState.Trusted,
            LastStateTransitionAt = DateTimeOffset.Parse("2026-06-18T10:00:00Z")
        });
        _presenceService.UpdatePeerPresence("rift-peer-listed", "online", "2026-06-18T10:05:00Z", ["presence.basic"]);

        var result = await _handler.ListTrustedPeersAsync();

        Assert.Contains(result.Peers, peer =>
            peer.DeviceId == "rift-peer-listed" &&
            peer.TrustState == "trusted" &&
            peer.PairedAt == "2026-06-18T10:00:00.0000000+00:00" &&
            peer.Presence == "online" &&
            peer.LastSeenAt == "2026-06-18T10:05:00Z");
    }

    [Fact]
    public async Task GetPeerPresenceAsync_ReturnsTrustedPeerPresence()
    {
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer-presence",
            Ed25519PublicKey = new byte[32],
            State = TrustState.Trusted,
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });
        _presenceService.UpdatePeerPresence("rift-peer-presence", "online", "2026-06-18T10:07:00Z", ["presence.basic", "security.event_log"]);

        var result = await _handler.GetPeerPresenceAsync("rift-peer-presence");

        Assert.Equal("rift-peer-presence", result.DeviceId);
        Assert.Equal("online", result.Status);
        Assert.Equal("2026-06-18T10:07:00Z", result.LastSeenAt);
        Assert.Contains("presence.basic", result.Capabilities);
    }

    [Fact]
    public async Task NotifyClipboardChangeAsync_BroadcastsToTrustedPeers()
    {
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer-clipboard",
            Ed25519PublicKey = new byte[32],
            State = TrustState.Trusted,
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });
        _presenceService.UpdatePeerPresence("rift-peer-clipboard", "online", null, ["clipboard.offer_fetch"]);

        var result = await _handler.NotifyClipboardChangeAsync("text/plain", 5, Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(Encoding.UTF8.GetBytes("hello"))), Convert.ToBase64String(Encoding.UTF8.GetBytes("hello")));

        Assert.Contains("rift-peer-clipboard", result.BroadcastTo);
        Assert.Contains(_transport.SentMessages, message => message.PeerDeviceId == "rift-peer-clipboard" && message.Type == "clipboard.offer");
    }

    [Fact]
    public async Task FetchClipboardContentAsync_ExpiredOffer_ReturnsOfferExpiredCode()
    {
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer-expired",
            Ed25519PublicKey = new byte[32],
            State = TrustState.Trusted,
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });
        _presenceService.UpdatePeerPresence("rift-peer-expired", "online", null, ["clipboard.offer_fetch"]);

        await _handler.NotifyClipboardChangeAsync(
            "text/plain",
            5,
            Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(Encoding.UTF8.GetBytes("hello"))),
            Convert.ToBase64String(Encoding.UTF8.GetBytes("hello")));

        await _clipboardService.HandleOfferReceivedAsync(new ReceivedClipboardOffer
        {
            DeviceId = "rift-peer-expired",
            PayloadSourceDeviceId = "rift-peer-expired",
            OfferId = "offer-expired",
            ContentType = "text/plain",
            ByteSize = 5,
            Sha256 = Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(Encoding.UTF8.GetBytes("hello"))),
            ExpiresInMs = -1,
            RequiredCapability = "clipboard.offer_fetch",
            OfferSequence = 1
        });

        var ex = await Assert.ThrowsAsync<LocalRpcException>(() => _handler.FetchClipboardContentAsync("offer-expired"));

        Assert.Equal(-32002, ex.ErrorCode);
    }

    [Fact]
    public async Task FetchClipboardContentAsync_SilentPeer_ReturnsTimeoutCode()
    {
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer-timeout",
            Ed25519PublicKey = new byte[32],
            State = TrustState.Trusted,
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });
        _presenceService.UpdatePeerPresence("rift-peer-timeout", "online", null, ["clipboard.offer_fetch"]);

        await _clipboardService.HandleOfferReceivedAsync(new ReceivedClipboardOffer
        {
            DeviceId = "rift-peer-timeout",
            PayloadSourceDeviceId = "rift-peer-timeout",
            OfferId = "offer-timeout",
            ContentType = "text/plain",
            ByteSize = 5,
            Sha256 = Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(Encoding.UTF8.GetBytes("hello"))),
            ExpiresInMs = 120000,
            RequiredCapability = "clipboard.offer_fetch",
            OfferSequence = 1
        });

        var ex = await Assert.ThrowsAsync<LocalRpcException>(() => _handler.FetchClipboardContentAsync("offer-timeout"));

        Assert.Equal(-32011, ex.ErrorCode);
    }

    [Fact]
    public async Task ApprovePairingAsync_WithWrongFingerprint_ReturnsAuthenticationFailed()
    {
        var peerPublicKey = new byte[32];
        peerPublicKey[0] = 0x42;
        var deviceId = IdentityManager.DeriveDeviceId(peerPublicKey);
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = deviceId,
            Ed25519PublicKey = peerPublicKey,
            State = TrustState.PairingPending,
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });

        var ex = await Assert.ThrowsAsync<LocalRpcException>(() => _handler.ApprovePairingAsync(deviceId, "WRONG-FINGERPRINT"));

        Assert.Equal(-32005, ex.ErrorCode);
    }

    [Fact]
    public async Task UnblockPeerAsync_RequiresBlockedState()
    {
        var peerPublicKey = new byte[32];
        peerPublicKey[0] = 0x24;
        var deviceId = IdentityManager.DeriveDeviceId(peerPublicKey);
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = deviceId,
            Ed25519PublicKey = peerPublicKey,
            State = TrustState.Trusted,
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });

        var ex = await Assert.ThrowsAsync<LocalRpcException>(() => _handler.UnblockPeerAsync(deviceId));

        Assert.Equal(-32008, ex.ErrorCode);
    }

    [Fact]
    public async Task QueryEventLogAsync_ReturnsPersistedPairingEvents()
    {
        var peerPublicKey = new byte[32];
        peerPublicKey[0] = 0x55;
        var deviceId = IdentityManager.DeriveDeviceId(peerPublicKey);
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = deviceId,
            Ed25519PublicKey = peerPublicKey,
            State = TrustState.Discovered,
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });

        await _handler.StartPairingAsync(deviceId);

        var result = await _handler.QueryEventLogAsync(eventTypes: ["pairing.attempted"]);

        Assert.NotEmpty(result.Events);
        Assert.Contains(result.Events, evt => evt.EventType == "pairing.attempted" && evt.PeerDeviceId == deviceId);
    }

    [Fact]
    public async Task StartPairingAsync_UnexpectedServiceFailure_ReturnsInternalError()
    {
        var handler = new RiftApiHandler(
            new DaemonInfoService(_identityManager, _securityEventLog, _trustStore, new DiscoveryCoordinator(_discoveryService, _trustStore), _presenceService),
            new DiscoveryCoordinator(_discoveryService, _trustStore),
            _clipboardService,
            new ThrowingPairingService());

        var ex = await Assert.ThrowsAsync<LocalRpcException>(() => handler.StartPairingAsync("rift-peer-failure"));

        Assert.Equal(-32603, ex.ErrorCode);
        Assert.Equal("boom", ex.Message);
    }

    public void Dispose()
    {
        SqliteConnection.ClearAllPools();
        if (File.Exists(_databasePath))
        {
            File.Delete(_databasePath);
        }
    }

    private sealed class FakeDiscoveryService : IDiscoveryService
    {
        public event EventHandler<PeerDiscoveredEventArgs>? PeerDiscovered;

        public bool IsDiscovering { get; private set; }

        public void StartAdvertising(string deviceId, string minVersion, string maxVersion)
        {
        }

        public void StopAdvertising()
        {
        }

        public void StartDiscovery()
        {
            IsDiscovering = true;
        }

        public void StopDiscovery()
        {
            IsDiscovering = false;
        }

        public void EmitPeerDiscovered(PeerDiscoveredEventArgs args)
        {
            PeerDiscovered?.Invoke(this, args);
        }
    }

    private sealed class FakeTransport : ITransport
    {
        public event EventHandler<MessageReceivedEventArgs>? MessageReceived;
        public event EventHandler<SessionStateChangedEventArgs>? SessionStateChanged;

        public List<(string PeerDeviceId, string Type)> SentMessages { get; } = [];

        public Task StartListeningAsync(CancellationToken cancellationToken) => Task.CompletedTask;

        public Task ConnectToPeerAsync(string host, int port, CancellationToken cancellationToken) => Task.CompletedTask;

        public Task SendAsync(string peerDeviceId, ReadOnlyMemory<byte> frameBody, CancellationToken cancellationToken)
        {
            using var document = JsonDocument.Parse(frameBody);
            SentMessages.Add((peerDeviceId, document.RootElement.GetProperty("type").GetString() ?? string.Empty));
            return Task.CompletedTask;
        }

        public Task DisconnectPeerAsync(string peerDeviceId, CancellationToken cancellationToken) => Task.CompletedTask;
    }

    private sealed class ThrowingPairingService : IPairingService
    {
        public Task<StartPairingResult> StartPairingAsync(string deviceId) => throw new InvalidOperationException("boom");

        public Task<ApprovePairingResult> ApprovePairingAsync(string deviceId, string fingerprint) => throw new InvalidOperationException("boom");

        public Task<RejectPairingResult> RejectPairingAsync(string deviceId) => throw new InvalidOperationException("boom");

        public Task<RevokeTrustResult> RevokeTrustAsync(string deviceId, string reason) => throw new InvalidOperationException("boom");

        public Task<UnblockPeerResult> UnblockPeerAsync(string deviceId) => throw new InvalidOperationException("boom");
    }
}
