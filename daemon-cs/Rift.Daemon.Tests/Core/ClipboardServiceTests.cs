using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Reflection;
using Microsoft.Data.Sqlite;
using Microsoft.Extensions.Logging.Abstractions;
using Rift.Daemon.Core;
using Rift.Daemon.Core.Cryptography;
using Rift.Daemon.Core.Data;
using Rift.Daemon.Core.Interfaces;

namespace Rift.Daemon.Tests.Core;

public sealed class ClipboardServiceTests : IDisposable
{
    private readonly string _databasePath;
    private readonly DatabaseContext _databaseContext;
    private readonly SqliteTrustStore _trustStore;
    private readonly SqliteSecurityEventLog _securityEventLog;
    private readonly IdentityManager _identityManager;
    private readonly PresenceService _presenceService;
    private readonly FakeTransport _transport;
    private readonly FakeDiscoveryCoordinator _discoveryCoordinator;
    private readonly FakeIpcNotificationService _ipcNotificationService;
    private readonly OperationService _operationService;
    private readonly ClipboardService _clipboardService;
    private static readonly TimeSpan FetchResponseTimeout = TimeSpan.FromMilliseconds(75);

    public ClipboardServiceTests()
    {
        _databasePath = Path.Combine(Path.GetTempPath(), $"rift-clipboard-{Guid.NewGuid():N}.db");
        _databaseContext = new DatabaseContext(_databasePath);
        _databaseContext.Initialize();
        _trustStore = new SqliteTrustStore(_databaseContext);
        _securityEventLog = new SqliteSecurityEventLog(_databaseContext);
        _identityManager = new IdentityManager(new SqliteLocalIdentityStore(_databaseContext));
        _presenceService = new PresenceService();
        _transport = new FakeTransport();
        _discoveryCoordinator = new FakeDiscoveryCoordinator();
        _ipcNotificationService = new FakeIpcNotificationService();
        _operationService = new OperationService(_ipcNotificationService, _securityEventLog, _identityManager, NullLogger<OperationService>.Instance);
        _clipboardService = new ClipboardService(_transport, _trustStore, _discoveryCoordinator, _presenceService, _identityManager, _securityEventLog, _operationService, _ipcNotificationService, NullLogger<ClipboardService>.Instance, FetchResponseTimeout);
    }

    [Fact]
    public async Task HandleOfferReceivedAsync_StoresNewestRemoteOffer()
    {
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer-a",
            Ed25519PublicKey = new byte[32],
            State = TrustState.Trusted,
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });
        _presenceService.UpdatePeerPresence("rift-peer-a", "online", null, ["clipboard.offer_fetch"]);

        await _clipboardService.HandleOfferReceivedAsync(new ReceivedClipboardOffer
        {
            DeviceId = "rift-peer-a",
            PayloadSourceDeviceId = "rift-peer-a",
            OfferId = "offer-1",
            ContentType = "text/plain",
            ByteSize = 5,
            Sha256 = "hash",
            ExpiresInMs = 120000,
            RequiredCapability = "clipboard.offer_fetch",
            OfferSequence = 1
        });

        var offers = await _clipboardService.ListClipboardOffersAsync();

        Assert.Contains(offers.Offers, offer => offer.OfferId == "offer-1" && offer.SourceDeviceId == "rift-peer-a");
    }

    [Fact]
    public async Task HandleOfferReceivedAsync_EmitsClipboardOfferNotificationWithMetadataOnly()
    {
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer-notify",
            Ed25519PublicKey = new byte[32],
            State = TrustState.Trusted,
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });
        _presenceService.UpdatePeerPresence("rift-peer-notify", "online", null, ["clipboard.offer_fetch"]);

        await _clipboardService.HandleOfferReceivedAsync(new ReceivedClipboardOffer
        {
            DeviceId = "rift-peer-notify",
            PayloadSourceDeviceId = "rift-peer-notify",
            OfferId = "offer-notify",
            ContentType = "text/plain",
            ByteSize = 5,
            Sha256 = "hash-notify",
            ExpiresInMs = 120000,
            RequiredCapability = "clipboard.offer_fetch",
            OfferSequence = 1
        });

        var notification = Assert.Single(_ipcNotificationService.Notifications);
        Assert.Equal("rift.onClipboardOffer", notification.Method);
        Assert.Equal("offer-notify", notification.Parameters["offerId"]?.ToString());
        Assert.Equal("rift-peer-notify", notification.Parameters["sourceDeviceId"]?.ToString());
        Assert.Equal("text/plain", notification.Parameters["contentType"]?.ToString());
        Assert.Equal("5", notification.Parameters["byteSize"]?.ToString());
        Assert.Equal("hash-notify", notification.Parameters["sha256"]?.ToString());
        Assert.Equal("120000", notification.Parameters["expiresInMs"]?.ToString());
        Assert.DoesNotContain("contentBase64", notification.Parameters.Keys);
    }

    [Fact]
    public async Task HandleOfferReceivedAsync_DoesNotMovePeerHighWaterMarkBackward()
    {
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer-replay",
            Ed25519PublicKey = new byte[32],
            State = TrustState.Trusted,
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });
        _presenceService.UpdatePeerPresence("rift-peer-replay", "online", null, ["clipboard.offer_fetch"]);

        await _clipboardService.HandleOfferReceivedAsync(new ReceivedClipboardOffer { DeviceId = "rift-peer-replay", PayloadSourceDeviceId = "rift-peer-replay", OfferId = "offer-5", ContentType = "text/plain", ByteSize = 5, Sha256 = "hash-5", ExpiresInMs = 120000, RequiredCapability = "clipboard.offer_fetch", OfferSequence = 5 });
        await _clipboardService.HandleOfferReceivedAsync(new ReceivedClipboardOffer { DeviceId = "rift-peer-replay", PayloadSourceDeviceId = "rift-peer-replay", OfferId = "offer-3", ContentType = "text/plain", ByteSize = 5, Sha256 = "hash-3", ExpiresInMs = 120000, RequiredCapability = "clipboard.offer_fetch", OfferSequence = 3 });
        await _clipboardService.HandleOfferReceivedAsync(new ReceivedClipboardOffer { DeviceId = "rift-peer-replay", PayloadSourceDeviceId = "rift-peer-replay", OfferId = "offer-4", ContentType = "text/plain", ByteSize = 5, Sha256 = "hash-4", ExpiresInMs = 120000, RequiredCapability = "clipboard.offer_fetch", OfferSequence = 4 });

        var offers = await _clipboardService.ListClipboardOffersAsync();
        var replayEvents = await _securityEventLog.QueryEventsAsync(new SecurityEventQuery
        {
            EventTypes = [SecurityEventTypes.ClipboardOfferReplay],
            PeerDeviceId = "rift-peer-replay",
            Limit = 10
        });

        Assert.Contains(offers.Offers, offer => offer.OfferId == "offer-5");
        Assert.DoesNotContain(offers.Offers, offer => offer.OfferId == "offer-3");
        Assert.DoesNotContain(offers.Offers, offer => offer.OfferId == "offer-4");
        Assert.Equal(2, replayEvents.Count);
    }

    [Fact]
    public async Task FetchClipboardContentAsync_RoundTripsFetchResponse()
    {
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer-b",
            Ed25519PublicKey = new byte[32],
            State = TrustState.Trusted,
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });
        _presenceService.UpdatePeerPresence("rift-peer-b", "online", null, ["clipboard.offer_fetch"]);

        await _clipboardService.HandleOfferReceivedAsync(new ReceivedClipboardOffer { DeviceId = "rift-peer-b", PayloadSourceDeviceId = "rift-peer-b", OfferId = "offer-2", ContentType = "text/plain", ByteSize = 5, Sha256 = Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes("hello"))), ExpiresInMs = 120000, RequiredCapability = "clipboard.offer_fetch", OfferSequence = 1 });

        var fetchTask = _clipboardService.FetchClipboardContentAsync("offer-2", CancellationToken.None);
        await _clipboardService.HandleFetchResponseAsync("rift-peer-b", "offer-2", Convert.ToBase64String(Encoding.UTF8.GetBytes("hello")), 5, Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes("hello"))), CancellationToken.None);

        var result = await fetchTask;

        Assert.Equal("offer-2", result.OfferId);
        Assert.True(result.Verified);
        Assert.Contains(_ipcNotificationService.Notifications, notification =>
            notification.Method == "rift.onOperationTransition" &&
            notification.Parameters["nextState"]?.ToString() == "Done");
    }

    [Fact]
    public async Task FetchClipboardContentAsync_AcceptsUppercaseSha256()
    {
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer-uppercase",
            Ed25519PublicKey = new byte[32],
            State = TrustState.Trusted,
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });
        _presenceService.UpdatePeerPresence("rift-peer-uppercase", "online", null, ["clipboard.offer_fetch"]);

        var lowercaseHash = Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes("hello")));
        await _clipboardService.HandleOfferReceivedAsync(new ReceivedClipboardOffer { DeviceId = "rift-peer-uppercase", PayloadSourceDeviceId = "rift-peer-uppercase", OfferId = "offer-uppercase", ContentType = "text/plain", ByteSize = 5, Sha256 = lowercaseHash, ExpiresInMs = 120000, RequiredCapability = "clipboard.offer_fetch", OfferSequence = 1 });

        var fetchTask = _clipboardService.FetchClipboardContentAsync("offer-uppercase", CancellationToken.None);
        await _clipboardService.HandleFetchResponseAsync("rift-peer-uppercase", "offer-uppercase", Convert.ToBase64String(Encoding.UTF8.GetBytes("hello")), 5, lowercaseHash.ToUpperInvariant(), CancellationToken.None);

        var result = await fetchTask;

        Assert.Equal("offer-uppercase", result.OfferId);
        Assert.True(result.Verified);
    }

    [Fact]
    public async Task FetchClipboardContentAsync_IgnoresResponseFromWrongDeviceAndTimesOut()
    {
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer-owner",
            Ed25519PublicKey = new byte[32],
            State = TrustState.Trusted,
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer-spoof",
            Ed25519PublicKey = new byte[32],
            State = TrustState.Trusted,
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });
        _presenceService.UpdatePeerPresence("rift-peer-owner", "online", null, ["clipboard.offer_fetch"]);
        _presenceService.UpdatePeerPresence("rift-peer-spoof", "online", null, ["clipboard.offer_fetch"]);

        var hash = Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes("hello")));
        await _clipboardService.HandleOfferReceivedAsync(new ReceivedClipboardOffer
        {
            DeviceId = "rift-peer-owner",
            PayloadSourceDeviceId = "rift-peer-owner",
            OfferId = "offer-wrong-device",
            ContentType = "text/plain",
            ByteSize = 5,
            Sha256 = hash,
            ExpiresInMs = 120000,
            RequiredCapability = "clipboard.offer_fetch",
            OfferSequence = 1
        });

        var fetchTask = _clipboardService.FetchClipboardContentAsync("offer-wrong-device", CancellationToken.None);
        await _clipboardService.HandleFetchResponseAsync(
            "rift-peer-spoof",
            "offer-wrong-device",
            Convert.ToBase64String(Encoding.UTF8.GetBytes("hello")),
            5,
            hash,
            CancellationToken.None);

        var ex = await Assert.ThrowsAsync<ClipboardFailureException>(() => fetchTask);
        var authFailures = await _securityEventLog.QueryEventsAsync(new SecurityEventQuery
        {
            EventTypes = [SecurityEventTypes.AuthFailed],
            PeerDeviceId = "rift-peer-spoof",
            Limit = 10
        });

        Assert.Equal("Timeout", ex.FailureReason);
        Assert.Contains(authFailures, evt => evt.FailureReason == "Unauthorized");
        Assert.Contains(_ipcNotificationService.Notifications, notification =>
            notification.Method == "rift.onOperationTransition" &&
            notification.Parameters["nextState"]?.ToString() == "Expired");
    }

    [Fact]
    public async Task FetchClipboardContentAsync_IgnoresSpoofedResponseAfterOfferRemovedFromRemoteOffers()
    {
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer-owner-removed",
            Ed25519PublicKey = new byte[32],
            State = TrustState.Trusted,
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer-spoof-removed",
            Ed25519PublicKey = new byte[32],
            State = TrustState.Trusted,
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });
        _presenceService.UpdatePeerPresence("rift-peer-owner-removed", "online", null, ["clipboard.offer_fetch"]);
        _presenceService.UpdatePeerPresence("rift-peer-spoof-removed", "online", null, ["clipboard.offer_fetch"]);

        var hash = Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes("hello")));
        await _clipboardService.HandleOfferReceivedAsync(new ReceivedClipboardOffer
        {
            DeviceId = "rift-peer-owner-removed",
            PayloadSourceDeviceId = "rift-peer-owner-removed",
            OfferId = "offer-removed-response",
            ContentType = "text/plain",
            ByteSize = 5,
            Sha256 = hash,
            ExpiresInMs = 120000,
            RequiredCapability = "clipboard.offer_fetch",
            OfferSequence = 1
        });

        var fetchTask = _clipboardService.FetchClipboardContentAsync("offer-removed-response", CancellationToken.None);
        await WaitForFetchRequestSentAsync("rift-peer-owner-removed");
        RemoveRemoteOffer("offer-removed-response");

        await _clipboardService.HandleFetchResponseAsync(
            "rift-peer-spoof-removed",
            "offer-removed-response",
            Convert.ToBase64String(Encoding.UTF8.GetBytes("hello")),
            5,
            hash,
            CancellationToken.None);

        var ex = await Assert.ThrowsAsync<ClipboardFailureException>(() => fetchTask);
        var authFailures = await _securityEventLog.QueryEventsAsync(new SecurityEventQuery
        {
            EventTypes = [SecurityEventTypes.AuthFailed],
            PeerDeviceId = "rift-peer-spoof-removed",
            Limit = 10
        });

        Assert.Equal("Timeout", ex.FailureReason);
        Assert.Contains(authFailures, evt => evt.FailureReason == "Unauthorized");
    }

    [Fact]
    public async Task FetchClipboardContentAsync_IgnoresSpoofedRejectAfterOfferRemovedFromRemoteOffers()
    {
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer-owner-reject",
            Ed25519PublicKey = new byte[32],
            State = TrustState.Trusted,
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer-spoof-reject",
            Ed25519PublicKey = new byte[32],
            State = TrustState.Trusted,
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });
        _presenceService.UpdatePeerPresence("rift-peer-owner-reject", "online", null, ["clipboard.offer_fetch"]);
        _presenceService.UpdatePeerPresence("rift-peer-spoof-reject", "online", null, ["clipboard.offer_fetch"]);

        await _clipboardService.HandleOfferReceivedAsync(new ReceivedClipboardOffer
        {
            DeviceId = "rift-peer-owner-reject",
            PayloadSourceDeviceId = "rift-peer-owner-reject",
            OfferId = "offer-removed-reject",
            ContentType = "text/plain",
            ByteSize = 5,
            Sha256 = "hash",
            ExpiresInMs = 120000,
            RequiredCapability = "clipboard.offer_fetch",
            OfferSequence = 1
        });

        var fetchTask = _clipboardService.FetchClipboardContentAsync("offer-removed-reject", CancellationToken.None);
        await WaitForFetchRequestSentAsync("rift-peer-owner-reject");
        RemoveRemoteOffer("offer-removed-reject");

        await _clipboardService.HandleFetchRejectAsync(
            "rift-peer-spoof-reject",
            "offer-removed-reject",
            "Unauthorized",
            "spoofed reject",
            CancellationToken.None);

        var ex = await Assert.ThrowsAsync<ClipboardFailureException>(() => fetchTask);
        var authFailures = await _securityEventLog.QueryEventsAsync(new SecurityEventQuery
        {
            EventTypes = [SecurityEventTypes.AuthFailed],
            PeerDeviceId = "rift-peer-spoof-reject",
            Limit = 10
        });

        Assert.Equal("Timeout", ex.FailureReason);
        Assert.Contains(authFailures, evt => evt.FailureReason == "Unauthorized");
    }

    [Fact]
    public async Task FetchClipboardContentAsync_TimesOutAndAllowsRetry()
    {
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer-timeout",
            Ed25519PublicKey = new byte[32],
            State = TrustState.Trusted,
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });
        _presenceService.UpdatePeerPresence("rift-peer-timeout", "online", null, ["clipboard.offer_fetch"]);

        await _clipboardService.HandleOfferReceivedAsync(new ReceivedClipboardOffer { DeviceId = "rift-peer-timeout", PayloadSourceDeviceId = "rift-peer-timeout", OfferId = "offer-timeout", ContentType = "text/plain", ByteSize = 5, Sha256 = "hash", ExpiresInMs = 120000, RequiredCapability = "clipboard.offer_fetch", OfferSequence = 1 });

        var firstAttempt = await Assert.ThrowsAsync<ClipboardFailureException>(() =>
            _clipboardService.FetchClipboardContentAsync("offer-timeout", CancellationToken.None));
        var secondAttempt = await Assert.ThrowsAsync<ClipboardFailureException>(() =>
            _clipboardService.FetchClipboardContentAsync("offer-timeout", CancellationToken.None));
        var timeoutEvents = await _securityEventLog.QueryEventsAsync(new SecurityEventQuery
        {
            EventTypes = [SecurityEventTypes.ClipboardFetched],
            PeerDeviceId = "rift-peer-timeout",
            Limit = 10
        });

        Assert.Equal("Timeout", firstAttempt.FailureReason);
        Assert.Equal("Timeout", secondAttempt.FailureReason);
        Assert.Equal(2, _transport.SentMessages.Count(message => message.PeerDeviceId == "rift-peer-timeout" && message.Type == "clipboard.fetchRequest"));
        Assert.Equal(2, timeoutEvents.Count(evt => evt.FailureReason == "Timeout"));
    }

    [Fact]
    public async Task ListClipboardOffersAsync_PrunesExpiredOfferAndEmitsExpiryNotification()
    {
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer-expired",
            Ed25519PublicKey = new byte[32],
            State = TrustState.Trusted,
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });
        _presenceService.UpdatePeerPresence("rift-peer-expired", "online", null, ["clipboard.offer_fetch"]);

        await _clipboardService.HandleOfferReceivedAsync(new ReceivedClipboardOffer
        {
            DeviceId = "rift-peer-expired",
            PayloadSourceDeviceId = "rift-peer-expired",
            OfferId = "offer-expired",
            ContentType = "text/plain",
            ByteSize = 5,
            Sha256 = "hash-expired",
            ExpiresInMs = -1,
            RequiredCapability = "clipboard.offer_fetch",
            OfferSequence = 1
        });

        _ipcNotificationService.Notifications.Clear();
        var result = await _clipboardService.ListClipboardOffersAsync();

        Assert.Empty(result.Offers);
        var notification = Assert.Single(_ipcNotificationService.Notifications);
        Assert.Equal("rift.onClipboardExpired", notification.Method);
        Assert.Equal("offer-expired", notification.Parameters["offerId"]?.ToString());
        Assert.DoesNotContain("contentBase64", notification.Parameters.Keys);
    }

    [Fact]
    public async Task HandleFetchRequestAsync_SendsFetchResponseForLocalOffer()
    {
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer-c",
            Ed25519PublicKey = new byte[32],
            State = TrustState.Trusted,
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });
        _presenceService.UpdatePeerPresence("rift-peer-c", "online", null, ["clipboard.offer_fetch"]);

        var hash = Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes("hello")));
        var notifyResult = await _clipboardService.NotifyClipboardChangeAsync("text/plain", 5, hash, Convert.ToBase64String(Encoding.UTF8.GetBytes("hello")), CancellationToken.None);
        await _clipboardService.HandleFetchRequestAsync("rift-peer-c", notifyResult.OfferId, "rift-peer-c", CancellationToken.None);

        Assert.Contains(_transport.SentMessages, message => message.PeerDeviceId == "rift-peer-c" && message.Type == "clipboard.fetchResponse");
    }

    [Fact]
    public async Task HandleOfferReceivedAsync_RejectsPayloadIdentityMismatch()
    {
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer-d",
            Ed25519PublicKey = new byte[32],
            State = TrustState.Trusted,
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });
        _presenceService.UpdatePeerPresence("rift-peer-d", "online", null, ["clipboard.offer_fetch"]);

        var ex = await Assert.ThrowsAsync<ClipboardFailureException>(() =>
            _clipboardService.HandleOfferReceivedAsync(new ReceivedClipboardOffer { DeviceId = "rift-peer-d", PayloadSourceDeviceId = "rift-other", OfferId = "offer-3", ContentType = "text/plain", ByteSize = 5, Sha256 = "hash", ExpiresInMs = 120000, RequiredCapability = "clipboard.offer_fetch", OfferSequence = 1 }));

        Assert.Equal("Unauthorized", ex.FailureReason);
    }

    [Fact]
    public async Task NotifyClipboardChangeAsync_OnlyBroadcastsToPeersWithNegotiatedClipboardCapability()
    {
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer-capable",
            Ed25519PublicKey = new byte[32],
            State = TrustState.Trusted,
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer-incapable",
            Ed25519PublicKey = new byte[32],
            State = TrustState.Trusted,
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });
        _presenceService.UpdatePeerPresence("rift-peer-capable", "online", null, ["clipboard.offer_fetch"]);
        _presenceService.UpdatePeerPresence("rift-peer-incapable", "online", null, ["presence.basic"]);

        var hash = Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes("hello")));
        var result = await _clipboardService.NotifyClipboardChangeAsync("text/plain", 5, hash, Convert.ToBase64String(Encoding.UTF8.GetBytes("hello")), CancellationToken.None);

        Assert.Contains("rift-peer-capable", result.BroadcastTo);
        Assert.DoesNotContain("rift-peer-incapable", result.BroadcastTo);
        Assert.Contains(_transport.SentMessages, message => message.PeerDeviceId == "rift-peer-capable" && message.Type == "clipboard.offer");
        Assert.DoesNotContain(_transport.SentMessages, message => message.PeerDeviceId == "rift-peer-incapable" && message.Type == "clipboard.offer");
    }

    [Fact]
    public async Task NotifyClipboardChangeAsync_ReconnectsTrustedPeerUsingPersistedEndpoint()
    {
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer-reconnect",
            Ed25519PublicKey = new byte[32],
            State = TrustState.Trusted,
            LastStateTransitionAt = DateTimeOffset.UtcNow,
            TrustedEndpoints =
            [
                new TrustedPeerEndpoint
                {
                    Address = "10.53.38.174",
                    Port = 9140,
                    Source = "manual",
                    AddressFamily = "InterNetwork",
                    LastSuccessAt = DateTimeOffset.UtcNow
                }
            ]
        });
        _presenceService.UpdatePeerPresence("rift-peer-reconnect", "online", null, ["clipboard.offer_fetch"]);
        _transport.AssumeConnectedByDefault = false;
        _transport.ActiveSessions.Clear();
        _transport.ConnectIdentityByEndpoint[("10.53.38.174", 9140)] = "rift-peer-reconnect";

        var hash = Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes("hello")));
        var result = await _clipboardService.NotifyClipboardChangeAsync(
            "text/plain",
            5,
            hash,
            Convert.ToBase64String(Encoding.UTF8.GetBytes("hello")),
            CancellationToken.None);

        Assert.Contains("rift-peer-reconnect", result.BroadcastTo);
        Assert.Contains(_transport.ConnectAttempts, attempt => attempt.Host == "10.53.38.174" && attempt.Port == 9140);
        Assert.Contains(_transport.SentMessages, message => message.PeerDeviceId == "rift-peer-reconnect" && message.Type == "clipboard.offer");
    }

    [Fact]
    public async Task FetchClipboardContentAsync_ReconnectsTrustedPeerUsingPersistedEndpoint()
    {
        var hash = Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes("hello")));
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer-fetch-reconnect",
            Ed25519PublicKey = new byte[32],
            State = TrustState.Trusted,
            LastStateTransitionAt = DateTimeOffset.UtcNow,
            TrustedEndpoints =
            [
                new TrustedPeerEndpoint
                {
                    Address = "10.53.38.175",
                    Port = 9140,
                    Source = "manual",
                    AddressFamily = "InterNetwork",
                    LastSuccessAt = DateTimeOffset.UtcNow
                }
            ]
        });
        _presenceService.UpdatePeerPresence("rift-peer-fetch-reconnect", "online", null, ["clipboard.offer_fetch"]);
        await _clipboardService.HandleOfferReceivedAsync(new ReceivedClipboardOffer
        {
            DeviceId = "rift-peer-fetch-reconnect",
            PayloadSourceDeviceId = "rift-peer-fetch-reconnect",
            OfferId = "offer-fetch-reconnect",
            ContentType = "text/plain",
            ByteSize = 5,
            Sha256 = hash,
            ExpiresInMs = 120000,
            RequiredCapability = "clipboard.offer_fetch",
            OfferSequence = 1
        });

        _transport.AssumeConnectedByDefault = false;
        _transport.ActiveSessions.Clear();
        _transport.ConnectIdentityByEndpoint[("10.53.38.175", 9140)] = "rift-peer-fetch-reconnect";

        var fetchTask = _clipboardService.FetchClipboardContentAsync("offer-fetch-reconnect", CancellationToken.None);
        await _clipboardService.HandleFetchResponseAsync(
            "rift-peer-fetch-reconnect",
            "offer-fetch-reconnect",
            Convert.ToBase64String(Encoding.UTF8.GetBytes("hello")),
            5,
            hash,
            CancellationToken.None);

        var result = await fetchTask;

        Assert.Equal("offer-fetch-reconnect", result.OfferId);
        Assert.Contains(_transport.ConnectAttempts, attempt => attempt.Host == "10.53.38.175" && attempt.Port == 9140);
        Assert.Contains(_transport.SentMessages, message => message.PeerDeviceId == "rift-peer-fetch-reconnect" && message.Type == "clipboard.fetchRequest");
    }

    [Fact]
    public async Task NotifyClipboardChangeAsync_UsesSingleReconnectAttemptForConcurrentOffers()
    {
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer-single-flight",
            Ed25519PublicKey = new byte[32],
            State = TrustState.Trusted,
            LastStateTransitionAt = DateTimeOffset.UtcNow,
            TrustedEndpoints =
            [
                new TrustedPeerEndpoint
                {
                    Address = "10.53.38.176",
                    Port = 9140,
                    Source = "manual",
                    AddressFamily = "InterNetwork",
                    LastSuccessAt = DateTimeOffset.UtcNow
                }
            ]
        });
        _presenceService.UpdatePeerPresence("rift-peer-single-flight", "online", null, ["clipboard.offer_fetch"]);
        _transport.AssumeConnectedByDefault = false;
        _transport.ActiveSessions.Clear();
        _transport.ConnectIdentityByEndpoint[("10.53.38.176", 9140)] = "rift-peer-single-flight";
        _transport.ConnectGate = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);

        var hashA = Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes("hello-a")));
        var hashB = Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes("hello-b")));

        var first = _clipboardService.NotifyClipboardChangeAsync(
            "text/plain",
            7,
            hashA,
            Convert.ToBase64String(Encoding.UTF8.GetBytes("hello-a")),
            CancellationToken.None);
        var second = _clipboardService.NotifyClipboardChangeAsync(
            "text/plain",
            7,
            hashB,
            Convert.ToBase64String(Encoding.UTF8.GetBytes("hello-b")),
            CancellationToken.None);

        await Task.Delay(50);
        _transport.ConnectGate.TrySetResult(true);
        await Task.WhenAll(first, second);

        Assert.Equal(1, _transport.ConnectAttempts.Count(attempt => attempt.Host == "10.53.38.176" && attempt.Port == 9140));
        Assert.Equal(2, _transport.SentMessages.Count(message => message.PeerDeviceId == "rift-peer-single-flight" && message.Type == "clipboard.offer"));
    }

    [Fact]
    public async Task NotifyClipboardChangeAsync_FallsBackToNextPersistedEndpointWhenFirstFails()
    {
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer-fallback",
            Ed25519PublicKey = new byte[32],
            State = TrustState.Trusted,
            LastStateTransitionAt = DateTimeOffset.UtcNow,
            TrustedEndpoints =
            [
                new TrustedPeerEndpoint
                {
                    Address = "10.53.38.177",
                    Port = 9140,
                    Source = "manual",
                    AddressFamily = "InterNetwork",
                    LastSuccessAt = DateTimeOffset.UtcNow.AddMinutes(-5)
                },
                new TrustedPeerEndpoint
                {
                    Address = "10.53.38.178",
                    Port = 9140,
                    Source = "fallback",
                    AddressFamily = "InterNetwork",
                    LastSuccessAt = DateTimeOffset.UtcNow
                }
            ]
        });
        _presenceService.UpdatePeerPresence("rift-peer-fallback", "online", null, ["clipboard.offer_fetch"]);
        _transport.AssumeConnectedByDefault = false;
        _transport.ActiveSessions.Clear();
        _transport.FailingEndpoints.Add(("10.53.38.177", 9140));
        _transport.ConnectIdentityByEndpoint[("10.53.38.178", 9140)] = "rift-peer-fallback";

        var hash = Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes("hello")));
        var result = await _clipboardService.NotifyClipboardChangeAsync(
            "text/plain",
            5,
            hash,
            Convert.ToBase64String(Encoding.UTF8.GetBytes("hello")),
            CancellationToken.None);

        Assert.Contains("rift-peer-fallback", result.BroadcastTo);
        Assert.Equal(2, _transport.ConnectAttempts.Count);
        Assert.Equal(("10.53.38.177", 9140), _transport.ConnectAttempts[0]);
        Assert.Equal(("10.53.38.178", 9140), _transport.ConnectAttempts[1]);
        Assert.Contains(_transport.SentMessages, message => message.PeerDeviceId == "rift-peer-fallback" && message.Type == "clipboard.offer");
    }

    [Fact]
    public async Task NotifyClipboardChangeAsync_FallsBackToDiscoveryWhenPersistedEndpointsMissing()
    {
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer-discovery-fallback",
            Ed25519PublicKey = new byte[32],
            State = TrustState.Trusted,
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });
        _presenceService.UpdatePeerPresence("rift-peer-discovery-fallback", "online", null, ["clipboard.offer_fetch"]);
        _transport.AssumeConnectedByDefault = false;
        _transport.ActiveSessions.Clear();
        _transport.ConnectIdentityByEndpoint[("192.168.1.55", 9140)] = "rift-peer-discovery-fallback";
        _discoveryCoordinator.Peers["rift-peer-discovery-fallback"] = new DiscoveredPeerInfo
        {
            DeviceId = "rift-peer-discovery-fallback",
            Address = "192.168.1.55",
            Port = 9140,
            TrustState = "trusted",
            ObservedEndpoints =
            [
                new DiscoveredPeerEndpoint
                {
                    Address = "192.168.1.55",
                    Port = 9140
                }
            ]
        };

        var hash = Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes("hello")));
        var result = await _clipboardService.NotifyClipboardChangeAsync(
            "text/plain",
            5,
            hash,
            Convert.ToBase64String(Encoding.UTF8.GetBytes("hello")),
            CancellationToken.None);

        Assert.Contains("rift-peer-discovery-fallback", result.BroadcastTo);
        Assert.Single(_transport.ConnectAttempts);
        Assert.Equal(("192.168.1.55", 9140), _transport.ConnectAttempts[0]);
        Assert.Contains(_transport.SentMessages, message => message.PeerDeviceId == "rift-peer-discovery-fallback" && message.Type == "clipboard.offer");
    }

    public void Dispose()
    {
        SqliteConnection.ClearAllPools();
        if (File.Exists(_databasePath))
        {
            File.Delete(_databasePath);
        }
    }

    // The fetch request is sent asynchronously inside FetchClipboardContentAsync;
    // spoofed response/reject tests must not race ahead of it.
    private async Task WaitForFetchRequestSentAsync(string peerDeviceId)
    {
        var deadline = DateTime.UtcNow.AddSeconds(5);
        while (!_transport.SentMessages.Any(message =>
                   message.PeerDeviceId == peerDeviceId &&
                   message.Type == "clipboard.fetchRequest"))
        {
            if (DateTime.UtcNow >= deadline)
            {
                throw new TimeoutException($"clipboard.fetchRequest to {peerDeviceId} was never sent.");
            }

            await Task.Delay(10);
        }
    }

    private void RemoveRemoteOffer(string offerId)
    {
        var field = typeof(ClipboardService).GetField("_remoteOffers", BindingFlags.Instance | BindingFlags.NonPublic);
        Assert.NotNull(field);

        var remoteOffers = field!.GetValue(_clipboardService);
        Assert.NotNull(remoteOffers);

        var tryRemove = remoteOffers!.GetType().GetMethod("TryRemove", [typeof(string), field.FieldType.GenericTypeArguments[1].MakeByRefType()]);
        Assert.NotNull(tryRemove);

        var parameters = new object?[] { offerId, null };
        _ = tryRemove!.Invoke(remoteOffers, parameters);
    }

    private sealed class FakeTransport : ITransport
    {
        private readonly object _gate = new();
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
        public List<(string Host, int Port)> ConnectAttempts { get; } = [];
        public Dictionary<(string Host, int Port), string> ConnectIdentityByEndpoint { get; } = [];
        public HashSet<(string Host, int Port)> FailingEndpoints { get; } = [];
        public HashSet<string> ActiveSessions { get; } = [];
        public bool AssumeConnectedByDefault { get; set; } = true;
        public TaskCompletionSource<bool>? ConnectGate { get; set; }

        public Task StartListeningAsync(CancellationToken cancellationToken) => Task.CompletedTask;

        public async Task ConnectToPeerAsync(string host, int port, CancellationToken cancellationToken)
        {
            lock (_gate)
            {
                ConnectAttempts.Add((host, port));
            }
            if (ConnectGate is not null)
            {
                await ConnectGate.Task.WaitAsync(cancellationToken);
            }
            if (FailingEndpoints.Contains((host, port)))
            {
                throw new InvalidOperationException($"Simulated connect failure for endpoint {host}:{port}");
            }
            if (ConnectIdentityByEndpoint.TryGetValue((host, port), out var peerDeviceId))
            {
                lock (_gate)
                {
                    ActiveSessions.Add(peerDeviceId);
                }
                return;
            }

            throw new InvalidOperationException($"No fake peer configured for endpoint {host}:{port}");
        }

        public Task<string> ConnectToPeerWithIdentityAsync(string host, int port, CancellationToken cancellationToken, string? expectedDeviceId = null) =>
            Task.FromResult("rift-test-peer");

        public Task SendAsync(string peerDeviceId, ReadOnlyMemory<byte> frameBody, CancellationToken cancellationToken)
        {
            lock (_gate)
            {
                if (!AssumeConnectedByDefault && !ActiveSessions.Contains(peerDeviceId))
                {
                    throw new InvalidOperationException($"No open session exists for {peerDeviceId}.");
                }
            }
            using var document = JsonDocument.Parse(frameBody);
            lock (_gate)
            {
                SentMessages.Add((peerDeviceId, document.RootElement.GetProperty("type").GetString() ?? string.Empty));
            }
            return Task.CompletedTask;
        }

        public bool HasActiveSession(string peerDeviceId)
        {
            lock (_gate)
            {
                return AssumeConnectedByDefault || ActiveSessions.Contains(peerDeviceId);
            }
        }
        public bool HasProtectedSession(string peerDeviceId)
        {
            lock (_gate)
            {
                return AssumeConnectedByDefault || ActiveSessions.Contains(peerDeviceId);
            }
        }
        public void RefreshSessionAuthorization(string peerDeviceId) { }
        public PeerSessionEndpoint? GetPeerSessionEndpoint(string peerDeviceId) => null;
        public Task DisconnectPeerAsync(string peerDeviceId, CancellationToken cancellationToken) => Task.CompletedTask;
    }

    private sealed class FakeDiscoveryCoordinator : IDiscoveryCoordinator
    {
        public Dictionary<string, DiscoveredPeerInfo> Peers { get; } = new(StringComparer.Ordinal);

        public DiscoveryToggleResult StartDiscovery() => new();

        public DiscoveryToggleResult StopDiscovery() => new();

        public ListDiscoveredPeersResult ListDiscoveredPeers() =>
            new()
            {
                Peers = Peers.Values.ToArray(),
                IsDiscovering = true
            };

        public bool TryGetDiscoveredPeer(string deviceId, out DiscoveredPeerInfo? peer)
        {
            var found = Peers.TryGetValue(deviceId, out var stored);
            peer = stored;
            return found;
        }
    }

    private sealed class FakeIpcNotificationService : IIpcNotificationService
    {
        public List<(string Method, Dictionary<string, object?> Parameters)> Notifications { get; } = [];

        public IDisposable RegisterClient(StreamJsonRpc.JsonRpc jsonRpc) => new NoOpRegistration();

        public Task NotifyAsync(string method, object parameters, CancellationToken cancellationToken = default)
        {
            var values = JsonSerializer.Deserialize<Dictionary<string, object?>>(
                JsonSerializer.Serialize(parameters),
                new JsonSerializerOptions
                {
                    PropertyNameCaseInsensitive = true
                }) ?? [];
            Notifications.Add((method, values));
            return Task.CompletedTask;
        }

        private sealed class NoOpRegistration : IDisposable
        {
            public void Dispose()
            {
            }
        }
    }
}
