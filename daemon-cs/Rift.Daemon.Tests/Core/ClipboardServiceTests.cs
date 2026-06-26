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
        _clipboardService = new ClipboardService(_transport, _trustStore, _presenceService, _identityManager, _securityEventLog, NullLogger<ClipboardService>.Instance, FetchResponseTimeout);
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

    public void Dispose()
    {
        SqliteConnection.ClearAllPools();
        if (File.Exists(_databasePath))
        {
            File.Delete(_databasePath);
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

        public bool HasActiveSession(string peerDeviceId) => false;
        public Task DisconnectPeerAsync(string peerDeviceId, CancellationToken cancellationToken) => Task.CompletedTask;
    }
}
