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
    private readonly OperationService _operationService;
    private readonly ClipboardService _clipboardService;
    private readonly FileTransferService _fileTransferService;
    private readonly SendQueueService _sendQueueService;
    private readonly FakeMediaPlaybackSyncService _mediaPlaybackSyncService;
    private readonly FakeNotificationSyncService _notificationSyncService;
    private readonly DeviceStatusService _deviceStatusService;
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
        var discoveryCoordinator = new DiscoveryCoordinator(_discoveryService, _trustStore, _identityManager);
        var daemonInfoService = new DaemonInfoService(_identityManager, _securityEventLog, _trustStore, discoveryCoordinator, _presenceService, _transport);
        _operationService = new OperationService(null, _securityEventLog, _identityManager, NullLogger<OperationService>.Instance);
        _clipboardService = new ClipboardService(_transport, _trustStore, discoveryCoordinator, _presenceService, _identityManager, _securityEventLog, _operationService, null, NullLogger<ClipboardService>.Instance, FetchResponseTimeout);
        _fileTransferService = new FileTransferService(_transport, _trustStore, discoveryCoordinator, _presenceService, _identityManager, _securityEventLog, _operationService, null, NullLogger<FileTransferService>.Instance);
        _sendQueueService = new SendQueueService(_trustStore, null);
        _mediaPlaybackSyncService = new FakeMediaPlaybackSyncService();
        _notificationSyncService = new FakeNotificationSyncService();
        _deviceStatusService = new DeviceStatusService(
            _transport,
            _presenceService,
            _identityManager,
            logger: NullLogger<DeviceStatusService>.Instance);
        var pairingService = new PairingService(
            _trustStore,
            _identityManager,
            _securityEventLog,
            pairingProtocolCoordinator: null,
            logger: NullLogger<PairingService>.Instance);
        _handler = new RiftApiHandler(daemonInfoService, discoveryCoordinator, _clipboardService, _fileTransferService, _sendQueueService, _operationService, pairingService, _mediaPlaybackSyncService, _notificationSyncService, _deviceStatusService);
    }

    [Fact]
    public async Task GetDeviceInfoAsync_ReturnsStableLocalIdentityMetadata()
    {
        var result = await _handler.GetDeviceInfoAsync();

        Assert.Equal(_identityManager.GetDeviceId(), result.DeviceId);
        Assert.Equal(_identityManager.GetDisplayName(), result.DisplayName);
        Assert.Equal(_identityManager.GetFingerprint(), result.Fingerprint);
        Assert.Equal("riftd-cs/0.1.0", result.ImplementationId);
        Assert.Equal("0.1-draft", result.ProtocolVersion);
        Assert.Contains(result.Capabilities, capability => capability.Name == "security.event_log");
        Assert.Contains(result.Capabilities, capability => capability.Name == "media.playback");
        Assert.Contains(result.Capabilities, capability => capability.Name == "notification.sync");
        Assert.Contains(result.Capabilities, capability => capability.Name == "device.status");
    }

    [Fact]
    public async Task NotifyLocalDeviceStatusAsync_CachesValidatedPowerState()
    {
        var result = await _handler.NotifyLocalDeviceStatusAsync(
            batteryPresent: true,
            batteryPercent: 64,
            chargingState: "charging",
            powerSource: "usb",
            lowPowerMode: false,
            observedAt: "2026-06-18T11:00:00Z",
            sourcePlatform: "android");

        Assert.Empty(result.BroadcastTo);
        var status = _deviceStatusService.GetDeviceStatus(_identityManager.GetDeviceId());
        Assert.NotNull(status);
        Assert.True(status!.BatteryPresent);
        Assert.Equal(64, status.BatteryPercent);
        Assert.Equal("charging", status.ChargingState);
        Assert.Equal("usb", status.PowerSource);
        Assert.False(status.LowPowerMode);
    }

    [Fact]
    public async Task NotifyLocalDeviceStatusAsync_RejectsNonRfc3339Timestamp()
    {
        var ex = await Assert.ThrowsAsync<LocalRpcException>(() =>
            _handler.NotifyLocalDeviceStatusAsync(
                batteryPresent: true,
                batteryPercent: 64,
                observedAt: "2026-06-18 11:00:00Z"));

        Assert.Equal(-32602, ex.ErrorCode);
    }

    [Fact]
    public async Task NotifyLocalDeviceStatusAsync_UsesNegotiatedSessionCapabilities()
    {
        const string peerDeviceId = "rift-peer-status-gate";
        _presenceService.UpdatePeerPresence(
            peerDeviceId,
            "online",
            DateTimeOffset.UtcNow.ToString("O"),
            ["device.status"]);

        var beforeSession = await _handler.NotifyLocalDeviceStatusAsync(
            batteryPresent: true,
            batteryPercent: 64);
        Assert.Empty(beforeSession.BroadcastTo);

        _transport.EmitSessionStateChanged(
            peerDeviceId,
            isOnline: true,
            selectedCapabilities: ["presence.basic"]);
        var withoutCapability = await _handler.NotifyLocalDeviceStatusAsync(
            batteryPresent: true,
            batteryPercent: 63);
        Assert.Empty(withoutCapability.BroadcastTo);

        _transport.EmitSessionStateChanged(
            peerDeviceId,
            isOnline: true,
            selectedCapabilities: ["device.status", "presence.basic"]);
        var withCapability = await _handler.NotifyLocalDeviceStatusAsync(
            batteryPresent: true,
            batteryPercent: 62);
        Assert.Contains(peerDeviceId, withCapability.BroadcastTo);
    }

    [Fact]
    public async Task NotifyLocalDeviceStatusAsync_ContinuesAfterPeerSendFailure()
    {
        const string failingPeer = "rift-peer-status-failing";
        const string healthyPeer = "rift-peer-status-healthy";
        _transport.EmitSessionStateChanged(
            failingPeer,
            isOnline: true,
            selectedCapabilities: ["device.status"]);
        _transport.EmitSessionStateChanged(
            healthyPeer,
            isOnline: true,
            selectedCapabilities: ["device.status"]);
        _transport.FailSendsTo.Add(failingPeer);

        var result = await _handler.NotifyLocalDeviceStatusAsync(
            batteryPresent: true,
            batteryPercent: 61);

        Assert.DoesNotContain(failingPeer, result.BroadcastTo);
        Assert.Contains(healthyPeer, result.BroadcastTo);
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

        Assert.Equal(deviceId, result.DeviceId);
        Assert.Equal(_identityManager.GetFingerprint(), result.Fingerprint);
        Assert.Equal(IdentityManager.DeriveFingerprint(peerPublicKey), result.PeerFingerprint);
        Assert.Equal(TrustState.PairingPending, storedPeer!.State);
    }

    [Fact]
    public async Task StartPairingByEndpointAsync_ReturnsResolvedPeerIdentity()
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

        var pairingCoordinator = new FakePairingProtocolCoordinator(deviceId);
        var pairingService = new PairingService(
            _trustStore,
            _identityManager,
            _securityEventLog,
            pairingCoordinator,
            logger: NullLogger<PairingService>.Instance);
        var handler = new RiftApiHandler(
            new DaemonInfoService(_identityManager, _securityEventLog, _trustStore, new DiscoveryCoordinator(_discoveryService, _trustStore, _identityManager), _presenceService, _transport),
            new DiscoveryCoordinator(_discoveryService, _trustStore, _identityManager),
            _clipboardService,
            _fileTransferService,
            _sendQueueService,
            _operationService,
            pairingService,
            _mediaPlaybackSyncService,
            _notificationSyncService);

        var result = await handler.StartPairingByEndpointAsync("10.53.38.174", 9140);

        Assert.Equal(deviceId, result.DeviceId);
        Assert.Equal(("10.53.38.174", 9140), pairingCoordinator.LastEndpoint);
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
        Assert.DoesNotContain(result.Peers, peer => peer.TrustState == "discovered");
    }

    [Fact]
    public async Task ListTrustedPeersAsync_HidesRevokedPeersFromVisibleDeviceList()
    {
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer-blocked",
            Ed25519PublicKey = new byte[32],
            State = TrustState.Blocked,
            LastStateTransitionAt = DateTimeOffset.Parse("2026-06-18T10:00:00Z")
        });
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer-revoked",
            Ed25519PublicKey = new byte[32],
            State = TrustState.Revoked,
            LastStateTransitionAt = DateTimeOffset.Parse("2026-06-18T10:01:00Z")
        });

        var result = await _handler.ListTrustedPeersAsync();

        Assert.Contains(result.Peers, peer => peer.DeviceId == "rift-peer-blocked" && peer.TrustState == "blocked");
        Assert.DoesNotContain(result.Peers, peer => peer.DeviceId == "rift-peer-revoked");
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
    public async Task EnqueueFileSendAsync_ReturnsQueueItem()
    {
        var path = Path.Combine(Path.GetTempPath(), $"rift-api-send-queue-{Guid.NewGuid():N}.txt");
        await File.WriteAllTextAsync(path, "hello");
        try
        {
            var result = await _handler.EnqueueFileSendAsync(path, "queued.txt", "text/plain");
            var listed = await _handler.ListSendQueueAsync();

            Assert.False(string.IsNullOrWhiteSpace(result.QueueItemId));
            Assert.Equal("waiting_for_target", result.Status);
            Assert.Contains(listed.Items, item => item.QueueItemId == result.QueueItemId && item.FileName == "queued.txt");
        }
        finally
        {
            await TestFiles.DeleteWithRetryAsync(path);
        }
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
    public async Task OfferFileAsync_SendsFileOfferToTrustedCapablePeer()
    {
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer-file",
            Ed25519PublicKey = new byte[32],
            State = TrustState.Trusted,
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });
        _presenceService.UpdatePeerPresence("rift-peer-file", "online", null, ["file.transfer"]);

        var tempFile = Path.Combine(Path.GetTempPath(), $"rift-api-file-{Guid.NewGuid():N}.txt");
        await File.WriteAllTextAsync(tempFile, "hello file");
        try
        {
            var result = await _handler.OfferFileAsync("rift-peer-file", tempFile, "demo.txt", "text/plain");

            Assert.Equal("rift-peer-file", result.TargetDeviceId);
            Assert.Equal("demo.txt", result.FileName);
            Assert.Contains(_transport.SentMessages, message =>
                message.PeerDeviceId == "rift-peer-file" &&
                message.Type == "file.offer");
        }
        finally
        {
            if (File.Exists(tempFile))
            {
                await TestFiles.DeleteWithRetryAsync(tempFile);
            }
        }
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
    public async Task ListAndGetOperationAsync_ReturnOperationHistory()
    {
        _operationService.CreateOperation("operation-1", "clipboard.fetch", "rift-local", "rift-peer");
        _operationService.TransitionOperation("operation-1", OperationState.Pending);
        _operationService.TransitionOperation("operation-1", OperationState.Dispatched);
        _operationService.TransitionOperation("operation-1", OperationState.Active);
        _operationService.TransitionOperation("operation-1", OperationState.Done);

        var listed = await _handler.ListOperationsAsync();
        var detailed = await _handler.GetOperationAsync("operation-1");

        Assert.Contains(listed.Operations, operation => operation.OperationId == "operation-1" && operation.State == "Done");
        Assert.Equal("clipboard.fetch", detailed.OperationType);
        Assert.Equal(4, detailed.Transitions.Count);
    }

    [Fact]
    public async Task ListOperationsAsync_PaginatesNewestFirst()
    {
        _operationService.CreateOperation("operation-a", "clipboard.fetch", "rift-local", "rift-peer-a");
        _operationService.CreateOperation("operation-b", "clipboard.fetch", "rift-local", "rift-peer-b");
        _operationService.CreateOperation("operation-c", "clipboard.fetch", "rift-local", "rift-peer-c");

        var listed = await _handler.ListOperationsAsync(limit: 1, offset: 1);

        Assert.Equal(3, listed.Total);
        Assert.Single(listed.Operations);
        Assert.Equal("operation-b", listed.Operations[0].OperationId);
    }

    [Fact]
    public async Task FetchClipboardContentAsync_SilentPeer_RecordsExpiredOperation()
    {
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer-timeout-operation",
            Ed25519PublicKey = new byte[32],
            State = TrustState.Trusted,
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });
        _presenceService.UpdatePeerPresence("rift-peer-timeout-operation", "online", null, ["clipboard.offer_fetch"]);

        await _clipboardService.HandleOfferReceivedAsync(new ReceivedClipboardOffer
        {
            DeviceId = "rift-peer-timeout-operation",
            PayloadSourceDeviceId = "rift-peer-timeout-operation",
            OfferId = "offer-timeout-operation",
            ContentType = "text/plain",
            ByteSize = 5,
            Sha256 = Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(Encoding.UTF8.GetBytes("hello"))),
            ExpiresInMs = 120000,
            RequiredCapability = "clipboard.offer_fetch",
            OfferSequence = 1
        });

        await Assert.ThrowsAsync<LocalRpcException>(() => _handler.FetchClipboardContentAsync("offer-timeout-operation"));

        var listed = await _handler.ListOperationsAsync(limit: 1, offset: 0);
        var latest = Assert.Single(listed.Operations);

        Assert.Equal("clipboard.fetch", latest.OperationType);
        Assert.Equal("Expired", latest.State);
        Assert.Equal("Timeout", latest.FailureReason);
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
    public async Task ResetRevokedPeerAsync_RemovesLegacyRevokedPeer()
    {
        var deviceId = "rift-revoked-peer";
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = deviceId,
            Ed25519PublicKey = new byte[32],
            State = TrustState.Trusted,
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });
        _trustStore.RevokePeer(deviceId, "user-request");

        var result = await _handler.ResetRevokedPeerAsync(deviceId);
        var peer = _trustStore.GetPeer(deviceId);

        Assert.True(result.Reset);
        Assert.Null(peer);
    }

    [Fact]
    public async Task RevokeTrustAsync_DeletesPeerForForgetFlow()
    {
        var deviceId = "rift-trusted-peer";
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = deviceId,
            DisplayName = "Linux Box",
            Platform = "linux",
            Ed25519PublicKey = new byte[32],
            State = TrustState.Trusted,
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });

        var result = await _handler.RevokeTrustAsync(deviceId, "user-request");
        var peer = _trustStore.GetPeer(deviceId);

        Assert.True(result.Revoked);
        Assert.Null(peer);
    }

    [Fact]
    public async Task RevokeTrustAsync_DeletesPeerEvenWhenNoOpenSessionExists()
    {
        var deviceId = "rift-trusted-peer-offline";
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = deviceId,
            DisplayName = "Offline Linux Box",
            Platform = "linux",
            Ed25519PublicKey = new byte[32],
            State = TrustState.Trusted,
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });

        var pairingService = new PairingService(
            _trustStore,
            _identityManager,
            _securityEventLog,
            pairingProtocolCoordinator: new FakePairingProtocolCoordinator("rift-manual-peer")
            {
                TrustRemoveException = new InvalidOperationException($"No open session exists for {deviceId}.")
            },
            logger: NullLogger<PairingService>.Instance);

        var result = await pairingService.RevokeTrustAsync(deviceId, "user-request");
        var peer = _trustStore.GetPeer(deviceId);

        Assert.True(result.Revoked);
        Assert.Null(peer);
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
    public async Task QueryEventLogAsync_InvalidSince_ReturnsInvalidParams()
    {
        var ex = await Assert.ThrowsAsync<LocalRpcException>(() =>
            _handler.QueryEventLogAsync(since: "not-a-timestamp"));

        Assert.Equal(-32602, ex.ErrorCode);
        Assert.Contains("since", ex.Message, StringComparison.Ordinal);
    }

    [Fact]
    public async Task NotificationSyncMethods_DelegateToNotificationService()
    {
        var localEvent = await _handler.NotifyLocalNotificationEventAsync(
            "posted",
            "notif-local-1",
            "dev.rift.desktop",
            "Rift Desktop",
            "Desktop test",
            "Mirrored to trusted peers",
            "2026-07-16T10:00:00Z",
            false,
            false,
            "windows");
        var listed = await _handler.ListNotificationsAsync();
        var action = await _handler.PerformNotificationActionAsync("rift-source", "notif-1", "open");
        var policy = await _handler.UpdateNotificationSyncPolicyAsync(
            true,
            mode: NotificationSyncPolicyModes.Exclude,
            packageNames: ["com.bank.example"]);

        Assert.Equal("notif-local-1", localEvent.NotificationId);
        Assert.Single(listed.Notifications);
        Assert.Equal("notif-1", listed.Notifications[0].NotificationId);
        Assert.Equal("operation-notification-1", action.OperationId);
        Assert.Equal("rift-source", action.SourceDeviceId);
        Assert.Equal("notif-1", action.NotificationId);
        Assert.Equal("open", action.Action);
        Assert.True(policy.Enabled);
        Assert.Equal(NotificationSyncPolicyModes.Exclude, policy.Mode);
        Assert.Equal(["com.bank.example"], policy.PackageNames);
    }

    [Fact]
    public async Task NotificationSyncPolicy_LegacyRequestIsProjectedToCanonicalPolicy()
    {
        var policy = await _handler.UpdateNotificationSyncPolicyAsync(
            true,
            blacklistedPackages: [" com.foo ", "com.foo"]);

        Assert.True(policy.Enabled);
        Assert.Equal(NotificationSyncPolicyModes.Exclude, policy.Mode);
        Assert.Equal(["com.foo"], policy.PackageNames);

        var emptyLegacyPolicy = await _handler.UpdateNotificationSyncPolicyAsync(
            true,
            blacklistedPackages: []);
        Assert.Equal(NotificationSyncPolicyModes.All, emptyLegacyPolicy.Mode);
        Assert.Empty(emptyLegacyPolicy.PackageNames);
    }

    [Fact]
    public async Task NotificationSyncPolicy_RejectsAmbiguousRequest()
    {
        var exception = await Assert.ThrowsAsync<LocalRpcException>(() =>
            _handler.UpdateNotificationSyncPolicyAsync(
                true,
                mode: NotificationSyncPolicyModes.Include,
                packageNames: ["com.foo"],
                blacklistedPackages: ["com.bar"]));

        Assert.Equal(-32602, exception.ErrorCode);
    }

    [Fact]
    public async Task NotificationSyncPolicy_RejectsInvalidMode()
    {
        var exception = await Assert.ThrowsAsync<LocalRpcException>(() =>
            _handler.UpdateNotificationSyncPolicyAsync(
                true,
                mode: "banana",
                packageNames: []));

        Assert.Equal(-32602, exception.ErrorCode);
    }

    [Fact]
    public async Task StartPairingAsync_UnexpectedServiceFailure_ReturnsInternalError()
    {
        var handler = new RiftApiHandler(
            new DaemonInfoService(_identityManager, _securityEventLog, _trustStore, new DiscoveryCoordinator(_discoveryService, _trustStore, _identityManager), _presenceService, _transport),
            new DiscoveryCoordinator(_discoveryService, _trustStore, _identityManager),
            _clipboardService,
            _fileTransferService,
            _sendQueueService,
            _operationService,
            new ThrowingPairingService(),
            _mediaPlaybackSyncService,
            _notificationSyncService);

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

    private sealed class FakeNotificationSyncService : INotificationSyncService
    {
        public Task<NotifyLocalNotificationEventResult> HandleLocalNotificationEventAsync(
            string eventType,
            NotificationSyncRecord notification,
            string? removedAt,
            CancellationToken cancellationToken)
        {
            return Task.FromResult(new NotifyLocalNotificationEventResult
            {
                NotificationId = notification.NotificationId,
                BroadcastTo = ["rift-peer"],
                Suppressed = false
            });
        }

        public Task<ListNotificationsResult> ListNotificationsAsync(CancellationToken cancellationToken)
        {
            return Task.FromResult(new ListNotificationsResult
            {
                Notifications =
                [
                    new NotificationSyncRecord
                    {
                        NotificationId = "notif-1",
                        SourceDeviceId = "rift-peer",
                        PackageName = "com.example.chat",
                        AppName = "Example Chat",
                        Title = "Riley",
                        BodyPreview = "See you at 6?",
                        PostedAt = "2026-07-14T10:00:00Z",
                        IsDismissible = true,
                        IsOpenable = true
                    }
                ],
                Policy = new NotificationSyncPolicy
                {
                    Enabled = true,
                    Mode = NotificationSyncPolicyModes.Exclude,
                    PackageNames = ["com.bank.example"]
                }
            });
        }

        public Task<PerformNotificationActionResult> PerformNotificationActionAsync(string sourceDeviceId, string notificationId, string action, CancellationToken cancellationToken)
        {
            return Task.FromResult(new PerformNotificationActionResult
            {
                OperationId = "operation-notification-1",
                SourceDeviceId = sourceDeviceId,
                NotificationId = notificationId,
                Action = action,
                State = "Pending"
            });
        }

        public Task<NotificationSyncPolicy> UpdateNotificationSyncPolicyAsync(bool enabled, string mode, IReadOnlyList<string> packageNames, CancellationToken cancellationToken)
        {
            return Task.FromResult(new NotificationSyncPolicy
            {
                Enabled = enabled,
                Mode = mode,
                PackageNames = packageNames.ToArray()
            });
        }

        public Task HandleNotificationPostedAsync(NotificationSyncRecord notification, CancellationToken cancellationToken) => Task.CompletedTask;

        public Task HandleNotificationUpdatedAsync(NotificationSyncRecord notification, CancellationToken cancellationToken) => Task.CompletedTask;

        public Task HandleNotificationRemovedAsync(NotificationRemovedRecord notification, CancellationToken cancellationToken) => Task.CompletedTask;

        public Task HandleNotificationActionResultAsync(NotificationActionResultRecord result, CancellationToken cancellationToken) => Task.CompletedTask;
    }

    private sealed class FakeMediaPlaybackSyncService : IMediaPlaybackSyncService
    {
        public Task<NotifyLocalMediaPlaybackEventResult> HandleLocalPlaybackEventAsync(string eventType, MediaPlaybackRecord playback, string? removedAt, CancellationToken cancellationToken)
        {
            return Task.FromResult(new NotifyLocalMediaPlaybackEventResult
            {
                PlaybackId = playback.PlaybackId,
                BroadcastTo = ["rift-peer"]
            });
        }

        public Task PublishLocalPlaybackToPeerAsync(string peerDeviceId, MediaPlaybackRecord playback, CancellationToken cancellationToken) =>
            Task.CompletedTask;

        public Task SendPeerErrorAsync(string peerDeviceId, string failureReason, string? refMessageId, string message, CancellationToken cancellationToken) =>
            Task.CompletedTask;

        public Task<ListMediaPlaybackResult> ListMediaPlaybackAsync(CancellationToken cancellationToken)
        {
            return Task.FromResult(new ListMediaPlaybackResult
            {
                Playbacks =
                [
                    new MediaPlaybackRecord
                    {
                        PlaybackId = "playback-1",
                        SourceDeviceId = "rift-peer",
                        AppId = "com.example.music",
                        AppName = "Example Music",
                        PlaybackState = "playing",
                        PositionMs = 1000,
                        CanPlay = true,
                        CanPause = true,
                        CanSkipNext = true,
                        CanSkipPrevious = true,
                        CanSeek = true,
                        UpdatedAt = "2026-07-16T10:00:00Z"
                    }
                ]
            });
        }

        public Task<MediaPlaybackRecord> GetMediaPlaybackAsync(string sourceDeviceId, string playbackId, CancellationToken cancellationToken) =>
            Task.FromResult(new MediaPlaybackRecord
            {
                PlaybackId = playbackId,
                SourceDeviceId = "rift-peer",
                AppId = "com.example.music",
                AppName = "Example Music",
                PlaybackState = "playing",
                PositionMs = 1000,
                CanPlay = true,
                CanPause = true,
                CanSkipNext = true,
                CanSkipPrevious = true,
                CanSeek = true,
                UpdatedAt = "2026-07-16T10:00:00Z"
            });

        public Task<PerformMediaPlaybackActionResult> PerformMediaPlaybackActionAsync(string sourceDeviceId, string playbackId, string action, long? positionMs, CancellationToken cancellationToken)
        {
            return Task.FromResult(new PerformMediaPlaybackActionResult
            {
                OperationId = "operation-media-1",
                PlaybackId = playbackId,
                Action = action,
                State = "Pending"
            });
        }

        public Task HandleMediaPlaybackActionRequestAsync(MediaPlaybackActionRequestRecord request, CancellationToken cancellationToken) =>
            Task.CompletedTask;

        public Task<ReportHandledMediaPlaybackActionResult> ReportHandledMediaPlaybackActionAsync(
            string requestId,
            bool success,
            string? failureReason,
            string? message,
            CancellationToken cancellationToken) =>
            Task.FromResult(new ReportHandledMediaPlaybackActionResult
            {
                RequestId = requestId,
                PlaybackId = "playback-1",
                Action = "play",
                Success = success
            });

        public Task HandleMediaPlaybackPostedAsync(MediaPlaybackRecord playback, CancellationToken cancellationToken) => Task.CompletedTask;
        public Task HandleMediaPlaybackUpdatedAsync(MediaPlaybackRecord playback, CancellationToken cancellationToken) => Task.CompletedTask;
        public Task HandleMediaPlaybackRemovedAsync(MediaPlaybackRemovedRecord playback, CancellationToken cancellationToken) => Task.CompletedTask;
        public Task HandleMediaPlaybackActionResultAsync(MediaPlaybackActionResultRecord result, CancellationToken cancellationToken) => Task.CompletedTask;
    }

    private sealed class FakeTransport : ITransport
    {
        public event EventHandler<MessageReceivedEventArgs>? MessageReceived
        {
            add { }
            remove { }
        }
        public event EventHandler<SessionStateChangedEventArgs>? SessionStateChanged;

        public List<(string PeerDeviceId, string Type)> SentMessages { get; } = [];
        public HashSet<string> FailSendsTo { get; } = new(StringComparer.Ordinal);

        public void EmitSessionStateChanged(
            string peerDeviceId,
            bool isOnline,
            IReadOnlyList<string> selectedCapabilities,
            bool allowsProtectedTraffic = true) =>
            SessionStateChanged?.Invoke(
                this,
                new SessionStateChangedEventArgs(
                    peerDeviceId,
                    isOnline,
                    selectedCapabilities,
                    allowsProtectedTraffic));

        public Task StartListeningAsync(CancellationToken cancellationToken) => Task.CompletedTask;

        public Task ConnectToPeerAsync(string host, int port, CancellationToken cancellationToken) => Task.CompletedTask;

        public Task<string> ConnectToPeerWithIdentityAsync(string host, int port, CancellationToken cancellationToken, string? expectedDeviceId = null) =>
            Task.FromResult("rift-manual-peer");

        public Task SendAsync(string peerDeviceId, ReadOnlyMemory<byte> frameBody, CancellationToken cancellationToken)
        {
            if (FailSendsTo.Contains(peerDeviceId))
            {
                throw new IOException("Simulated device status send failure.");
            }

            using var document = JsonDocument.Parse(frameBody);
            SentMessages.Add((peerDeviceId, document.RootElement.GetProperty("type").GetString() ?? string.Empty));
            return Task.CompletedTask;
        }

        public bool HasActiveSession(string peerDeviceId) => true;
        public bool HasProtectedSession(string peerDeviceId) => true;
        public void RefreshSessionAuthorization(string peerDeviceId) { }
        public PeerSessionEndpoint? GetPeerSessionEndpoint(string peerDeviceId) => null;
        public Task DisconnectPeerAsync(string peerDeviceId, CancellationToken cancellationToken) => Task.CompletedTask;
    }

    private sealed class ThrowingPairingService : IPairingService
    {
        public Task<StartPairingResult> StartPairingAsync(string deviceId) => throw new InvalidOperationException("boom");

        public Task<StartPairingResult> StartPairingByEndpointAsync(string address, int port) => throw new InvalidOperationException("boom");

        public Task<ApprovePairingResult> ApprovePairingAsync(string deviceId, string fingerprint) => throw new InvalidOperationException("boom");

        public Task<RejectPairingResult> RejectPairingAsync(string deviceId) => throw new InvalidOperationException("boom");

        public Task<RevokeTrustResult> RevokeTrustAsync(string deviceId, string reason) => throw new InvalidOperationException("boom");

        public Task<UnblockPeerResult> UnblockPeerAsync(string deviceId) => throw new InvalidOperationException("boom");

        public Task<ResetRevokedPeerResult> ResetRevokedPeerAsync(string deviceId) => throw new InvalidOperationException("boom");
    }

    private sealed class FakePairingProtocolCoordinator : IPairingProtocolCoordinator
    {
        private readonly string _resolvedDeviceId;

        public FakePairingProtocolCoordinator(string resolvedDeviceId)
        {
            _resolvedDeviceId = resolvedDeviceId;
        }

        public (string Host, int Port)? LastEndpoint { get; private set; }
        public Exception? TrustRemoveException { get; set; }

        public Task<string> ConnectToEndpointForPairingAsync(string host, int port, CancellationToken cancellationToken = default)
        {
            LastEndpoint = (host, port);
            return Task.FromResult(_resolvedDeviceId);
        }

        public Task HandleMessageAsync(string peerDeviceId, ReadOnlyMemory<byte> payload, CancellationToken cancellationToken) => Task.CompletedTask;

        public Task NotifyLocalPairingApprovedAsync(string deviceId, CancellationToken cancellationToken = default) => Task.CompletedTask;

        public Task NotifyLocalPairingRejectedAsync(string deviceId, CancellationToken cancellationToken = default) => Task.CompletedTask;

        public Task NotifyLocalPairingStartedAsync(string deviceId, CancellationToken cancellationToken = default) => Task.CompletedTask;

        public Task NotifyLocalTrustRemovedAsync(string deviceId, string reason, CancellationToken cancellationToken = default)
        {
            if (TrustRemoveException is not null)
            {
                return Task.FromException(TrustRemoveException);
            }

            return Task.CompletedTask;
        }
    }
}
