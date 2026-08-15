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
    private readonly FileTransferService _fileTransferService;
    private readonly MediaPlaybackSyncService _mediaPlaybackSyncService;
    private readonly NotificationSyncService _notificationSyncService;
    private readonly DeviceStatusService _deviceStatusService;
    private readonly OperationService _operationService;
    private readonly FakeTransport _clipboardTransport;
    private readonly FakeTransport _pairingTransport;
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
        var discoveryCoordinator = new DiscoveryCoordinator(new FakeDiscoveryService(), _trustStore, _identityManager);
        _clipboardTransport = new FakeTransport();
        _pairingTransport = new FakeTransport();
        _operationService = new OperationService(null, _securityEventLog, _identityManager, NullLogger<OperationService>.Instance);
        _clipboardService = new ClipboardService(_clipboardTransport, _trustStore, discoveryCoordinator, _presenceService, _identityManager, _securityEventLog, _operationService, null, NullLogger<ClipboardService>.Instance, TimeSpan.FromMilliseconds(250));
        _pairingCoordinator = new PairingProtocolCoordinator(
            _pairingTransport,
            discoveryCoordinator,
            _trustStore,
            _identityManager,
            _securityEventLog,
            logger: NullLogger<PairingProtocolCoordinator>.Instance);
        _fileTransferService = new FileTransferService(
            _clipboardTransport,
            _trustStore,
            discoveryCoordinator,
            _presenceService,
            _identityManager,
            _securityEventLog,
            _operationService,
            null,
            NullLogger<FileTransferService>.Instance);
        _mediaPlaybackSyncService = new MediaPlaybackSyncService(
            _clipboardTransport,
            _presenceService,
            _identityManager,
            _operationService,
            _securityEventLog,
            logger: NullLogger<MediaPlaybackSyncService>.Instance);
        _notificationSyncService = new NotificationSyncService(
            _clipboardTransport,
            _presenceService,
            _identityManager,
            _operationService,
            _securityEventLog,
            null,
            NullLogger<NotificationSyncService>.Instance);
        _deviceStatusService = new DeviceStatusService(
            _clipboardTransport,
            _presenceService,
            _identityManager,
            logger: NullLogger<DeviceStatusService>.Instance);
        _router = new ProtocolMessageRouter(
            _pairingCoordinator,
            _presenceService,
            _clipboardService,
            _fileTransferService,
            _mediaPlaybackSyncService,
            _notificationSyncService,
            _deviceStatusService,
            _securityEventLog,
            _identityManager);
    }

    [Fact]
    public async Task SendPeerErrorAsync_OmitsNullReferenceMessageId()
    {
        await _deviceStatusService.SendPeerErrorAsync(
            "rift-peer-error",
            "MalformedMessage",
            refMessageId: null,
            message: "Invalid device status payload",
            CancellationToken.None);

        var error = Assert.Single(_clipboardTransport.Payloads);
        var payload = error.GetProperty("payload");
        Assert.Equal("MalformedMessage", payload.GetProperty("failureReason").GetString());
        Assert.False(payload.TryGetProperty("refMessageId", out _));
        Assert.Equal("Invalid device status payload", payload.GetProperty("message").GetString());
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

        await _router.HandleMessageAsync(CreateSession("rift-peer-presence", ["clipboard.offer_fetch", "presence.basic", "operation.lifecycle", "security.event_log"]), CreateEnvelope("rift-peer-presence", "presence.update", new
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
    public async Task HandleMessageAsync_DeviceStatusUpdated_CachesPeerPowerState()
    {
        const string peerDeviceId = "rift-peer-device-status";
        await _router.HandleMessageAsync(
            CreateSession(peerDeviceId, ["device.status"]),
            CreateEnvelope(peerDeviceId, "device.statusUpdated", new
            {
                sourceDeviceId = peerDeviceId,
                sourcePlatform = "android",
                batteryPresent = true,
                batteryPercent = 64,
                chargingState = "charging",
                powerSource = "usb",
                lowPowerMode = false,
                observedAt = "2026-06-18T11:00:00Z"
            }),
            CancellationToken.None);

        var status = _deviceStatusService.GetDeviceStatus(peerDeviceId);
        Assert.NotNull(status);
        Assert.True(status!.BatteryPresent);
        Assert.Equal(64, status.BatteryPercent);
        Assert.Equal("charging", status.ChargingState);
        Assert.Equal("usb", status.PowerSource);
        Assert.False(status.LowPowerMode);
        Assert.False(status.IsStale);
    }

    [Fact]
    public async Task HandleMessageAsync_DeviceStatusUpdated_RejectsWrongTypedOptionalField()
    {
        const string peerDeviceId = "rift-peer-device-status-type";
        await _router.HandleMessageAsync(
            CreateSession(peerDeviceId, ["device.status"]),
            CreateEnvelope(peerDeviceId, "device.statusUpdated", new
            {
                sourceDeviceId = peerDeviceId,
                batteryPresent = "false",
                powerSource = "ac",
                observedAt = "2026-06-18T11:00:00Z"
            }),
            CancellationToken.None);

        Assert.Null(_deviceStatusService.GetDeviceStatus(peerDeviceId));
        var error = Assert.Single(_clipboardTransport.Payloads);
        Assert.Equal("error", error.GetProperty("type").GetString());
        Assert.Equal("MalformedMessage", error.GetProperty("payload").GetProperty("failureReason").GetString());
    }

    [Fact]
    public async Task HandleMessageAsync_DeviceStatusUpdated_AuditsSpoofedPayloadIdentity()
    {
        const string peerDeviceId = "rift-peer-device-status-spoof";
        await _router.HandleMessageAsync(
            CreateSession(peerDeviceId, ["device.status"]),
            CreateEnvelope(peerDeviceId, "device.statusUpdated", new
            {
                sourceDeviceId = "rift-spoofed-device-status",
                batteryPresent = true,
                batteryPercent = 64,
                observedAt = "2026-06-18T11:00:00Z"
            }),
            CancellationToken.None);

        Assert.Null(_deviceStatusService.GetDeviceStatus(peerDeviceId));
        var events = await _securityEventLog.QueryEventsAsync(new SecurityEventQuery
        {
            EventTypes = [SecurityEventTypes.AuthFailed],
            PeerDeviceId = peerDeviceId
        });
        var securityEvent = Assert.Single(events);
        Assert.Equal(SecurityEventSeverity.Critical, securityEvent.Severity);
        Assert.Equal(SecurityEventOutcome.Denied, securityEvent.Outcome);
        Assert.Equal("Unauthorized", securityEvent.FailureReason);
        Assert.Equal("device.statusUpdated", securityEvent.Details!["messageType"]);
        Assert.Equal("sourceDeviceId", securityEvent.Details["identityField"]);

        var error = Assert.Single(_clipboardTransport.Payloads);
        Assert.Equal("Unauthorized", error.GetProperty("payload").GetProperty("failureReason").GetString());
    }

    [Fact]
    public async Task HandleMessageAsync_PresenceUpdate_RejectsSpoofedSourceDeviceId()
    {
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer-presence-spoof",
            Ed25519PublicKey = new byte[32],
            State = TrustState.Trusted,
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });

        var ex = await Assert.ThrowsAsync<UnauthorizedAccessException>(() => _router.HandleMessageAsync(CreateSession("rift-peer-presence-spoof", ["clipboard.offer_fetch", "presence.basic", "operation.lifecycle", "security.event_log"]), CreateEnvelope("rift-spoofed", "presence.update", new
        {
            status = "online",
            lastSeenAt = "2026-06-18T11:00:00Z",
            capabilities = new[] { "presence.basic" }
        }), CancellationToken.None));

        Assert.Contains("sourceDeviceId", ex.Message, StringComparison.Ordinal);
        Assert.Null(_presenceService.GetPeerPresence("rift-peer-presence-spoof"));
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

        var ex = await Assert.ThrowsAsync<ClipboardFailureException>(() => _router.HandleMessageAsync(CreateSession("rift-peer-clipboard", ["clipboard.offer_fetch", "presence.basic", "operation.lifecycle", "security.event_log"]), CreateEnvelope("rift-peer-clipboard", "clipboard.offer", new
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

    [Fact]
    public async Task HandleMessageAsync_PairingMessage_RejectsSpoofedSourceDeviceId()
    {
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer-pairing-spoof",
            Ed25519PublicKey = new byte[32],
            State = TrustState.Discovered,
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });

        var ex = await Assert.ThrowsAsync<UnauthorizedAccessException>(() => _router.HandleMessageAsync(CreateSession("rift-peer-pairing-spoof", [], allowsProtectedTraffic: false), CreateEnvelope("rift-spoofed", "pairing.start", new
        {
            expiresInMs = 120000
        }), CancellationToken.None));

        var peer = _trustStore.GetPeer("rift-peer-pairing-spoof");

        Assert.Contains("sourceDeviceId", ex.Message, StringComparison.Ordinal);
        Assert.Equal(TrustState.Discovered, peer!.State);
    }

    [Fact]
    public async Task HandleMessageAsync_TrustRemove_RoutesToPairingCoordinatorForTrustedPeer()
    {
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer-trust-remove",
            Ed25519PublicKey = new byte[32],
            State = TrustState.Trusted,
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });

        await _router.HandleMessageAsync(
            CreateSession("rift-peer-trust-remove", ["presence.basic"], allowsProtectedTraffic: true),
            CreateEnvelope("rift-peer-trust-remove", "trust.remove", new
            {
                removedDeviceId = _identityManager.GetDeviceId(),
                reason = "Peer removed this device",
                removedAt = "2026-07-14T08:00:00Z"
            }),
            CancellationToken.None);

        Assert.Null(_trustStore.GetPeer("rift-peer-trust-remove"));
    }

    [Fact]
    public async Task HandleMessageAsync_ClipboardFetchRequest_RoutesToClipboardService()
    {
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer-fetch-request",
            Ed25519PublicKey = new byte[32],
            State = TrustState.Trusted,
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });
        _presenceService.UpdatePeerPresence("rift-peer-fetch-request", "online", null, ["clipboard.offer_fetch"]);

        var hash = Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(Encoding.UTF8.GetBytes("hello")));
        var offer = await _clipboardService.NotifyClipboardChangeAsync("text/plain", 5, hash, Convert.ToBase64String(Encoding.UTF8.GetBytes("hello")), CancellationToken.None);

        await _router.HandleMessageAsync(CreateSession("rift-peer-fetch-request", ["clipboard.offer_fetch", "presence.basic", "operation.lifecycle", "security.event_log"]), CreateEnvelope("rift-peer-fetch-request", "clipboard.fetchRequest", new
        {
            offerId = offer.OfferId,
            requestingDeviceId = "rift-peer-fetch-request"
        }), CancellationToken.None);

        Assert.Contains(_clipboardTransport.SentMessages, sent => sent.PeerDeviceId == "rift-peer-fetch-request" && sent.Type == "clipboard.fetchResponse");
    }

    [Fact]
    public async Task HandleMessageAsync_ClipboardFetchResponse_RoutesToClipboardService()
    {
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer-fetch-response",
            Ed25519PublicKey = new byte[32],
            State = TrustState.Trusted,
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });
        _presenceService.UpdatePeerPresence("rift-peer-fetch-response", "online", null, ["clipboard.offer_fetch"]);

        var hash = Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(Encoding.UTF8.GetBytes("hello")));
        await _clipboardService.HandleOfferReceivedAsync(new ReceivedClipboardOffer
        {
            DeviceId = "rift-peer-fetch-response",
            PayloadSourceDeviceId = "rift-peer-fetch-response",
            OfferId = "offer-fetch-response",
            ContentType = "text/plain",
            ByteSize = 5,
            Sha256 = hash,
            ExpiresInMs = 120000,
            RequiredCapability = "clipboard.offer_fetch",
            OfferSequence = 1
        });

        var fetchTask = _clipboardService.FetchClipboardContentAsync("offer-fetch-response", CancellationToken.None);
        await WaitForConditionAsync(
            () => _clipboardTransport.SentMessages.Any(sent => sent.PeerDeviceId == "rift-peer-fetch-response" && sent.Type == "clipboard.fetchRequest"),
            TimeSpan.FromSeconds(1));
        await _router.HandleMessageAsync(CreateSession("rift-peer-fetch-response", ["clipboard.offer_fetch", "presence.basic", "operation.lifecycle", "security.event_log"]), CreateEnvelope("rift-peer-fetch-response", "clipboard.fetchResponse", new
        {
            offerId = "offer-fetch-response",
            contentBase64 = Convert.ToBase64String(Encoding.UTF8.GetBytes("hello")),
            byteSize = 5,
            sha256 = hash
        }), CancellationToken.None);

        var result = await fetchTask;
        Assert.True(result.Verified);
    }

    [Fact]
    public async Task HandleMessageAsync_ClipboardFetchReject_RoutesToClipboardService()
    {
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer-fetch-reject",
            Ed25519PublicKey = new byte[32],
            State = TrustState.Trusted,
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });
        _presenceService.UpdatePeerPresence("rift-peer-fetch-reject", "online", null, ["clipboard.offer_fetch"]);

        await _clipboardService.HandleOfferReceivedAsync(new ReceivedClipboardOffer
        {
            DeviceId = "rift-peer-fetch-reject",
            PayloadSourceDeviceId = "rift-peer-fetch-reject",
            OfferId = "offer-fetch-reject",
            ContentType = "text/plain",
            ByteSize = 5,
            Sha256 = "hash",
            ExpiresInMs = 120000,
            RequiredCapability = "clipboard.offer_fetch",
            OfferSequence = 1
        });

        var fetchTask = _clipboardService.FetchClipboardContentAsync("offer-fetch-reject", CancellationToken.None);
        await _router.HandleMessageAsync(CreateSession("rift-peer-fetch-reject", ["clipboard.offer_fetch", "presence.basic", "operation.lifecycle", "security.event_log"]), CreateEnvelope("rift-peer-fetch-reject", "clipboard.fetchReject", new
        {
            offerId = "offer-fetch-reject",
            failureReason = "Unauthorized",
            message = "not allowed"
        }), CancellationToken.None);

        var ex = await Assert.ThrowsAsync<ClipboardFailureException>(() => fetchTask);
        Assert.Equal("Unauthorized", ex.FailureReason);
    }

    [Fact]
    public async Task HandleMessageAsync_FileOffer_RoutesToFileTransferService()
    {
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer-file-offer",
            Ed25519PublicKey = new byte[32],
            State = TrustState.Trusted,
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });
        _presenceService.UpdatePeerPresence("rift-peer-file-offer", "online", null, ["file.transfer"]);

        await _router.HandleMessageAsync(
            CreateSession("rift-peer-file-offer", ["file.transfer", "presence.basic", "operation.lifecycle", "security.event_log"]),
            CreateEnvelope("rift-peer-file-offer", "file.offer", new
            {
                transferId = "transfer-offer-1",
                fileName = "demo.txt",
                mediaType = "text/plain",
                byteSize = 5,
                sha256 = Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(Encoding.UTF8.GetBytes("hello"))),
                chunkSize = 262144,
                chunkCount = 1,
                expiresInMs = 120000,
                sourceDeviceId = "rift-peer-file-offer",
                requiredCapability = "file.transfer"
            }),
            CancellationToken.None);

        var offers = await _fileTransferService.ListIncomingFileOffersAsync();
        Assert.Contains(offers.Offers, offer =>
            offer.TransferId == "transfer-offer-1" &&
            offer.SourceDeviceId == "rift-peer-file-offer" &&
            offer.FileName == "demo.txt");
    }

    [Fact]
    public async Task HandleMessageAsync_FileAccept_StartsOutgoingChunkSend()
    {
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer-file-accept",
            Ed25519PublicKey = new byte[32],
            State = TrustState.Trusted,
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });
        _presenceService.UpdatePeerPresence("rift-peer-file-accept", "online", null, ["file.transfer"]);

        var tempFile = Path.Combine(Path.GetTempPath(), $"rift-file-{Guid.NewGuid():N}.txt");
        await File.WriteAllTextAsync(tempFile, "hello");
        try
        {
            var offer = await _fileTransferService.OfferFileAsync(
                "rift-peer-file-accept",
                tempFile,
                "demo.txt",
                "text/plain",
                CancellationToken.None);

            await _router.HandleMessageAsync(
                CreateSession("rift-peer-file-accept", ["file.transfer", "presence.basic", "operation.lifecycle", "security.event_log"]),
                CreateEnvelope("rift-peer-file-accept", "file.accept", new
                {
                    transferId = offer.TransferId,
                    receivingDeviceId = "rift-peer-file-accept",
                    chunkSize = 262144
                }),
                CancellationToken.None);

            await WaitForConditionAsync(
                () => _clipboardTransport.SentMessages.Any(sent =>
                    sent.PeerDeviceId == "rift-peer-file-accept" &&
                    sent.Type == "file.complete"),
                TimeSpan.FromSeconds(5));

            Assert.Contains(_clipboardTransport.SentMessages, sent =>
                sent.PeerDeviceId == "rift-peer-file-accept" &&
                sent.Type == "file.chunk");
        }
        finally
        {
            await TestFiles.DeleteWithRetryAsync(tempFile);
        }
    }

    [Fact]
    public async Task HandleMessageAsync_NotificationPosted_RoutesToNotificationSyncService()
    {
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer-notification",
            Ed25519PublicKey = new byte[32],
            State = TrustState.Trusted,
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });

        await _router.HandleMessageAsync(
            CreateSession("rift-peer-notification", ["notification.sync", "presence.basic", "operation.lifecycle", "security.event_log"]),
            CreateEnvelope("rift-peer-notification", "notification.posted", new
            {
                notificationId = "notif-router-1",
                sourceDeviceId = "rift-peer-notification",
                packageName = "com.example.chat",
                appName = "Example Chat",
                title = "Riley",
                bodyPreview = "See you at 6?",
                postedAt = "2026-07-14T10:00:00Z",
                isDismissible = true,
                isOpenable = true,
                icon = new
                {
                    mediaType = "image/png",
                    dataBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==",
                    byteSize = 70,
                    sha256 = "4ff6ab670a58c14270e034e2090d9a432caa263a14e0a25785386b0c12f880b5"
                }
            }),
            CancellationToken.None);

        var notifications = await _notificationSyncService.ListNotificationsAsync(CancellationToken.None);
        var notification = Assert.Single(
            notifications.Notifications,
            notification => notification.NotificationId == "notif-router-1");
        Assert.Equal(
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==",
            notification.Icon!["dataBase64"]);
    }

    [Fact]
    public async Task HandleMessageAsync_NotificationPosted_DropsMalformedIconOnly()
    {
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer-invalid-icon",
            Ed25519PublicKey = new byte[32],
            State = TrustState.Trusted,
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });

        await _router.HandleMessageAsync(
            CreateSession("rift-peer-invalid-icon", ["notification.sync", "presence.basic", "operation.lifecycle", "security.event_log"]),
            CreateEnvelope("rift-peer-invalid-icon", "notification.posted", new
            {
                notificationId = "notif-router-invalid-icon",
                sourceDeviceId = "rift-peer-invalid-icon",
                packageName = "com.example.chat",
                appName = "Example Chat",
                postedAt = "2026-07-14T10:00:00Z",
                isDismissible = true,
                isOpenable = false,
                icon = new
                {
                    mediaType = "image/png",
                    dataBase64 = "AQID",
                    byteSize = 3,
                    sha256 = new string('0', 64)
                }
            }),
            CancellationToken.None);

        var notifications = await _notificationSyncService.ListNotificationsAsync(CancellationToken.None);
        var notification = Assert.Single(
            notifications.Notifications,
            notification => notification.NotificationId == "notif-router-invalid-icon");
        Assert.Null(notification.Icon);
    }

    [Fact]
    public async Task HandleMessageAsync_NotificationPosted_RejectsWhenCapabilityWasNotNegotiated()
    {
        await Assert.ThrowsAsync<UnauthorizedAccessException>(() => _router.HandleMessageAsync(
            CreateSession("rift-peer-notification", ["presence.basic", "operation.lifecycle", "security.event_log"]),
            CreateEnvelope("rift-peer-notification", "notification.posted", new
            {
                notificationId = "notif-router-unauthorized",
                sourceDeviceId = "rift-peer-notification",
                packageName = "com.example.chat",
                appName = "Example Chat",
                postedAt = "2026-07-14T10:00:00Z",
                isDismissible = true,
                isOpenable = true
            }),
            CancellationToken.None));
    }

    [Fact]
    public async Task HandleMessageAsync_RejectsProtectedMessageWhenCapabilityWasNotNegotiated()
    {
        await Assert.ThrowsAsync<UnauthorizedAccessException>(() => _router.HandleMessageAsync(
            CreateSession("rift-peer-no-presence", ["clipboard.offer_fetch", "security.event_log", "operation.lifecycle"]),
            CreateEnvelope("rift-peer-no-presence", "presence.update", new
            {
                status = "online",
                capabilities = new[] { "presence.basic" }
            }),
            CancellationToken.None));
    }

    [Fact]
    public async Task HandleMessageAsync_MediaPlaybackActionRequest_ValidatesRequesterIdentity()
    {
        const string peerDeviceId = "rift-peer-media-action";
        await _mediaPlaybackSyncService.HandleMediaPlaybackPostedAsync(new MediaPlaybackRecord
        {
            PlaybackId = "playback-1",
            SourceDeviceId = _identityManager.GetDeviceId(),
            AppId = "com.example.music",
            AppName = "Example Music",
            PlaybackState = "playing",
            CanPause = true,
            UpdatedAt = "2026-07-20T10:00:00Z"
        }, CancellationToken.None);

        await _router.HandleMessageAsync(
            CreateSession(peerDeviceId, ["media.playback"]),
            CreateEnvelope(peerDeviceId, "media.playbackActionRequest", new
            {
                operationId = Guid.NewGuid().ToString("D"),
                playbackId = "playback-1",
                sourceDeviceId = _identityManager.GetDeviceId(),
                requestingDeviceId = peerDeviceId,
                action = "pause",
                positionMs = (long?)null,
                requestedAt = "2026-07-20T10:00:00Z"
            }),
            CancellationToken.None);

        Assert.Contains(
            _clipboardTransport.SentMessages,
            sent => sent.PeerDeviceId == peerDeviceId && sent.Type == "media.playbackActionResult");
    }

    [Fact]
    public async Task HandleMessageAsync_MediaPlaybackArtwork_PreservesStringValues()
    {
        const string peerDeviceId = "rift-peer-media-artwork";

        await _router.HandleMessageAsync(
            CreateSession(peerDeviceId, ["media.playback"]),
            CreateEnvelope(peerDeviceId, "media.playbackPosted", new
            {
                playbackId = "playback-1",
                sourceDeviceId = peerDeviceId,
                appId = "com.example.music",
                appName = "Example Music",
                title = "Example Track",
                artwork = new
                {
                    dataBase64 = "aW1hZ2U=",
                    mediaType = "image/jpeg",
                    uri = "file:///tmp/artwork.jpg"
                },
                playbackState = "playing",
                positionMs = 1000,
                durationMs = 2000,
                canPlay = false,
                canPause = true,
                canSkipNext = true,
                canSkipPrevious = true,
                canSeek = true,
                updatedAt = "2026-07-20T10:00:00Z"
            }),
            CancellationToken.None);

        var playback = await _mediaPlaybackSyncService.GetMediaPlaybackAsync(
            peerDeviceId,
            "playback-1",
            CancellationToken.None);

        Assert.Equal("aW1hZ2U=", playback.Artwork!["dataBase64"]);
        Assert.Equal("image/jpeg", playback.Artwork["mediaType"]);
        Assert.Equal("file:///tmp/artwork.jpg", playback.Artwork["uri"]);
        Assert.All(playback.Artwork.Values, value => Assert.IsType<string>(value));
    }

    [Fact]
    public async Task HandleMessageAsync_MalformedMediaPlayback_SendsPeerError()
    {
        const string peerDeviceId = "rift-peer-malformed-media";

        await _router.HandleMessageAsync(
            CreateSession(peerDeviceId, ["media.playback"]),
            CreateEnvelope(peerDeviceId, "media.playbackPosted", new
            {
                playbackId = "playback-1",
                sourceDeviceId = peerDeviceId,
                appId = "com.example.music",
                appName = "Example Music",
                playbackState = "playing",
                positionMs = -1,
                canPlay = true,
                canPause = true,
                canSkipNext = true,
                canSkipPrevious = true,
                canSeek = true,
                updatedAt = "2026-07-20T10:00:00Z"
            }),
            CancellationToken.None);

        var error = Assert.Single(_clipboardTransport.Payloads, payload =>
            payload.GetProperty("type").GetString() == "error");
        Assert.Equal("MalformedMessage", error.GetProperty("payload").GetProperty("failureReason").GetString());
    }

    [Fact]
    public async Task HandleMessageAsync_MalformedOptionalMediaTimestamps_SendPeerErrors()
    {
        const string peerDeviceId = "rift-peer-media-timestamps";

        await _router.HandleMessageAsync(
            CreateSession(peerDeviceId, ["media.playback"]),
            CreateEnvelope(peerDeviceId, "media.playbackActionRequest", new
            {
                operationId = Guid.NewGuid().ToString("D"),
                playbackId = "playback-1",
                sourceDeviceId = _identityManager.GetDeviceId(),
                requestingDeviceId = peerDeviceId,
                action = "pause",
                requestedAt = "2026-07-20"
            }),
            CancellationToken.None);
        await _router.HandleMessageAsync(
            CreateSession(peerDeviceId, ["media.playback"]),
            CreateEnvelope(peerDeviceId, "media.playbackRemoved", new
            {
                playbackId = "playback-1",
                sourceDeviceId = peerDeviceId,
                removedAt = "2026-07-20T10:00:00+01:00"
            }),
            CancellationToken.None);

        Assert.Equal(2, _clipboardTransport.Payloads.Count(payload =>
            payload.GetProperty("type").GetString() == "error" &&
            payload.GetProperty("payload").GetProperty("failureReason").GetString() == "MalformedMessage"));
    }

    [Fact]
    public async Task HandleMessageAsync_MediaPlaybackActionRequest_RequiresOperationId()
    {
        const string peerDeviceId = "rift-peer-media-action";

        await _router.HandleMessageAsync(
            CreateSession(peerDeviceId, ["media.playback"]),
            CreateEnvelope(peerDeviceId, "media.playbackActionRequest", new
            {
                playbackId = "playback-1",
                sourceDeviceId = _identityManager.GetDeviceId(),
                requestingDeviceId = peerDeviceId,
                action = "pause"
            }),
            CancellationToken.None);

        var error = Assert.Single(_clipboardTransport.Payloads, payload =>
            payload.GetProperty("type").GetString() == "error");
        Assert.Equal("MalformedMessage", error.GetProperty("payload").GetProperty("failureReason").GetString());
    }

    [Fact]
    public async Task HandleMessageAsync_MediaPlaybackActionRequest_RejectsSpoofedRequester()
    {
        const string peerDeviceId = "rift-peer-media-action";

        await _router.HandleMessageAsync(
            CreateSession(peerDeviceId, ["media.playback"]),
            CreateEnvelope(peerDeviceId, "media.playbackActionRequest", new
            {
                operationId = Guid.NewGuid().ToString("D"),
                playbackId = "playback-1",
                sourceDeviceId = _identityManager.GetDeviceId(),
                requestingDeviceId = "rift-spoofed-requester",
                action = "pause"
            }),
            CancellationToken.None);

        var error = Assert.Single(_clipboardTransport.Payloads, payload =>
            payload.GetProperty("type").GetString() == "error");
        Assert.Equal("Unauthorized", error.GetProperty("payload").GetProperty("failureReason").GetString());
    }

    [Fact]
    public async Task HandleMessageAsync_MediaPlaybackActionResult_RejectsSpoofedRequester()
    {
        const string peerDeviceId = "rift-peer-media-result";

        await _router.HandleMessageAsync(
            CreateSession(peerDeviceId, ["media.playback"]),
            CreateEnvelope(peerDeviceId, "media.playbackActionResult", new
            {
                operationId = Guid.NewGuid().ToString("D"),
                playbackId = "playback-1",
                sourceDeviceId = peerDeviceId,
                requestingDeviceId = "rift-spoofed-requester",
                action = "pause",
                success = true
            }),
            CancellationToken.None);

        var error = Assert.Single(_clipboardTransport.Payloads, payload =>
            payload.GetProperty("type").GetString() == "error");
        Assert.Equal("Unauthorized", error.GetProperty("payload").GetProperty("failureReason").GetString());
    }

    [Fact]
    public async Task HandleMessageAsync_MediaPlaybackWithoutCapability_SendsCapabilityUnavailable()
    {
        const string peerDeviceId = "rift-peer-media-capability";

        await _router.HandleMessageAsync(
            CreateSession(peerDeviceId, []),
            CreateEnvelope(peerDeviceId, "media.playbackRemoved", new
            {
                playbackId = "playback-1",
                sourceDeviceId = peerDeviceId
            }),
            CancellationToken.None);

        var error = Assert.Single(_clipboardTransport.Payloads, payload =>
            payload.GetProperty("type").GetString() == "error");
        Assert.Equal("CapabilityUnavailable", error.GetProperty("payload").GetProperty("failureReason").GetString());
    }

    [Fact]
    public async Task HandleMessageAsync_RejectsProtectedMessageForDiagnosticOnlySession()
    {
        await Assert.ThrowsAsync<UnauthorizedAccessException>(() => _router.HandleMessageAsync(
            CreateSession("rift-peer-diagnostic", ["presence.basic"], allowsProtectedTraffic: false),
            CreateEnvelope("rift-peer-diagnostic", "presence.update", new
            {
                status = "online",
                capabilities = new[] { "presence.basic" }
            }),
            CancellationToken.None));
    }

    public void Dispose()
    {
        SqliteConnection.ClearAllPools();
        if (File.Exists(_databasePath))
        {
            File.Delete(_databasePath);
        }
    }

    private static async Task WaitForConditionAsync(Func<bool> condition, TimeSpan timeout)
    {
        var deadline = DateTime.UtcNow.Add(timeout);
        while (!condition())
        {
            if (DateTime.UtcNow >= deadline)
            {
                throw new TimeoutException("Condition was not met within the allotted time.");
            }

            await Task.Delay(10);
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

    private static SessionPeerContext CreateSession(string peerDeviceId, IReadOnlyList<string> capabilities, bool allowsProtectedTraffic = true)
    {
        return new SessionPeerContext(peerDeviceId, capabilities, allowsProtectedTraffic);
    }

    private sealed class FakeDiscoveryService : IDiscoveryService
    {
        public event EventHandler<PeerDiscoveredEventArgs>? PeerDiscovered
        {
            add { }
            remove { }
        }

        public void StartAdvertising(string deviceId, string minVersion, string maxVersion) { }

        public void StopAdvertising() { }

        public void StartDiscovery() { }

        public void StopDiscovery() { }
    }

    private sealed class FakeTransport : ITransport
    {
        public event EventHandler<MessageReceivedEventArgs>? MessageReceived
        {
            add { }
            remove { }
        }
        public event EventHandler<SessionStateChangedEventArgs>? SessionStateChanged
        {
            add { }
            remove { }
        }

        public List<(string PeerDeviceId, string Type)> SentMessages { get; } = [];
        public List<JsonElement> Payloads { get; } = [];

        public Task StartListeningAsync(CancellationToken cancellationToken) => Task.CompletedTask;

        public Task ConnectToPeerAsync(string host, int port, CancellationToken cancellationToken) => Task.CompletedTask;

        public Task<string> ConnectToPeerWithIdentityAsync(string host, int port, CancellationToken cancellationToken, string? expectedDeviceId = null) =>
            Task.FromResult("rift-test-peer");

        public Task SendAsync(string peerDeviceId, ReadOnlyMemory<byte> frameBody, CancellationToken cancellationToken)
        {
            using var document = JsonDocument.Parse(frameBody);
            SentMessages.Add((peerDeviceId, document.RootElement.GetProperty("type").GetString() ?? string.Empty));
            Payloads.Add(document.RootElement.Clone());
            return Task.CompletedTask;
        }

        public bool HasActiveSession(string peerDeviceId) => true;
        public bool HasProtectedSession(string peerDeviceId) => true;
        public void RefreshSessionAuthorization(string peerDeviceId) { }
        public PeerSessionEndpoint? GetPeerSessionEndpoint(string peerDeviceId) => null;
        public Task DisconnectPeerAsync(string peerDeviceId, CancellationToken cancellationToken) => Task.CompletedTask;
    }
}
