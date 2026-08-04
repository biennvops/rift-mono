using System.Text;
using System.Text.Json;
using Microsoft.Data.Sqlite;
using Microsoft.Extensions.Logging.Abstractions;
using Rift.Daemon.Core;
using Rift.Daemon.Core.Cryptography;
using Rift.Daemon.Core.Data;
using Rift.Daemon.Core.Interfaces;
using SkiaSharp;
using StreamJsonRpc;

namespace Rift.Daemon.Tests.Core;

public sealed class MediaPlaybackSyncServiceTests : IDisposable
{
    private readonly string _databasePath;
    private readonly DatabaseContext _databaseContext;
    private readonly SqliteSecurityEventLog _securityEventLog;
    private readonly IdentityManager _identityManager;
    private readonly PresenceService _presenceService;
    private readonly RecordingTransport _transport;
    private readonly RecordingIpcNotificationService _ipcNotificationService;
    private readonly OperationService _operationService;

    public MediaPlaybackSyncServiceTests()
    {
        _databasePath = Path.Combine(Path.GetTempPath(), $"rift-media-playback-{Guid.NewGuid():N}.db");
        _databaseContext = new DatabaseContext(_databasePath);
        _databaseContext.Initialize();
        _securityEventLog = new SqliteSecurityEventLog(_databaseContext);
        _identityManager = new IdentityManager(new SqliteLocalIdentityStore(_databaseContext));
        _presenceService = new PresenceService();
        _transport = new RecordingTransport();
        _ipcNotificationService = new RecordingIpcNotificationService();
        _operationService = new OperationService(_ipcNotificationService, _securityEventLog, _identityManager, NullLogger<OperationService>.Instance);
    }

    [Fact]
    public async Task HandleMediaPlaybackActionRequestAsync_UsesLocalActionHandlerWhenRegistered()
    {
        var localActionHandler = new RecordingLocalMediaPlaybackActionHandler();
        var service = new MediaPlaybackSyncService(
            _transport,
            _presenceService,
            _identityManager,
            _operationService,
            _securityEventLog,
            _ipcNotificationService,
            localActionHandler,
            NullLogger<MediaPlaybackSyncService>.Instance);
        await service.HandleMediaPlaybackPostedAsync(
            CreatePlayback(_identityManager.GetDeviceId(), "playback-1", "Track"),
            CancellationToken.None);

        await service.HandleMediaPlaybackActionRequestAsync(new MediaPlaybackActionRequestRecord
        {
            PlaybackId = "playback-1",
            SourceDeviceId = _identityManager.GetDeviceId(),
            RequestingDeviceId = "rift-peer",
            Action = "pause"
        }, CancellationToken.None);

        var handled = Assert.Single(localActionHandler.Requests);
        Assert.Equal("playback-1", handled.PlaybackId);
        Assert.DoesNotContain(_ipcNotificationService.Events, evt => evt.Method == "rift.onMediaPlaybackActionRequest");
        var sent = Assert.Single(_transport.SentMessages);
        Assert.Equal("rift-peer", sent.PeerDeviceId);
        Assert.Equal("media.playbackActionResult", sent.Type);
    }

    [Fact]
    public async Task HandleMediaPlaybackActionRequestAsync_ReportsLocalHandlerFailure()
    {
        var localActionHandler = new RecordingLocalMediaPlaybackActionHandler
        {
            Result = new LocalMediaPlaybackActionResult
            {
                Success = false,
                FailureReason = "CapabilityUnavailable",
                Message = "adapter failed"
            }
        };
        var service = new MediaPlaybackSyncService(
            _transport,
            _presenceService,
            _identityManager,
            _operationService,
            _securityEventLog,
            _ipcNotificationService,
            localActionHandler,
            NullLogger<MediaPlaybackSyncService>.Instance);
        await service.HandleMediaPlaybackPostedAsync(
            CreatePlayback(_identityManager.GetDeviceId(), "playback-1", "Track"),
            CancellationToken.None);

        await service.HandleMediaPlaybackActionRequestAsync(new MediaPlaybackActionRequestRecord
        {
            PlaybackId = "playback-1",
            SourceDeviceId = _identityManager.GetDeviceId(),
            RequestingDeviceId = "rift-peer",
            Action = "play"
        }, CancellationToken.None);

        var payload = Assert.Single(_transport.Payloads);
        Assert.False(payload.GetProperty("payload").GetProperty("success").GetBoolean());
        Assert.Equal("CapabilityUnavailable", payload.GetProperty("payload").GetProperty("failureReason").GetString());
    }

    [Fact]
    public async Task HandleMediaPlaybackActionRequestAsync_RejectsMissingOrDisallowedLocalPlayback()
    {
        var localActionHandler = new RecordingLocalMediaPlaybackActionHandler();
        var service = new MediaPlaybackSyncService(
            _transport,
            _presenceService,
            _identityManager,
            _operationService,
            _securityEventLog,
            _ipcNotificationService,
            localActionHandler,
            NullLogger<MediaPlaybackSyncService>.Instance);

        await service.HandleMediaPlaybackActionRequestAsync(new MediaPlaybackActionRequestRecord
        {
            PlaybackId = "missing",
            SourceDeviceId = _identityManager.GetDeviceId(),
            RequestingDeviceId = "rift-peer",
            Action = "pause"
        }, CancellationToken.None);
        await service.HandleMediaPlaybackPostedAsync(new MediaPlaybackRecord
        {
            PlaybackId = "restricted",
            SourceDeviceId = _identityManager.GetDeviceId(),
            AppId = "com.example.music",
            AppName = "Example Music",
            PlaybackState = "paused",
            UpdatedAt = "2026-07-16T10:00:00Z"
        }, CancellationToken.None);
        await service.HandleMediaPlaybackActionRequestAsync(new MediaPlaybackActionRequestRecord
        {
            PlaybackId = "restricted",
            SourceDeviceId = _identityManager.GetDeviceId(),
            RequestingDeviceId = "rift-peer",
            Action = "seek",
            PositionMs = 1000
        }, CancellationToken.None);

        Assert.Empty(localActionHandler.Requests);
        Assert.Equal(2, _transport.Payloads.Count(payload =>
            payload.GetProperty("type").GetString() == "media.playbackActionResult" &&
            payload.GetProperty("payload").GetProperty("failureReason").GetString() == "CapabilityUnavailable"));
    }

    [Fact]
    public async Task HandleMediaPlaybackActionRequestAsync_ExpiresUnhandledIpcRequest()
    {
        var service = CreateService(actionTimeout: TimeSpan.FromMilliseconds(50));
        await service.HandleMediaPlaybackPostedAsync(
            CreatePlayback(_identityManager.GetDeviceId(), "playback-1", "Track"),
            CancellationToken.None);

        await service.HandleMediaPlaybackActionRequestAsync(new MediaPlaybackActionRequestRecord
        {
            PlaybackId = "playback-1",
            SourceDeviceId = _identityManager.GetDeviceId(),
            RequestingDeviceId = "rift-peer",
            Action = "pause"
        }, CancellationToken.None);

        await Task.Delay(150);
        var result = Assert.Single(_transport.Payloads, payload =>
            payload.GetProperty("type").GetString() == "media.playbackActionResult");
        Assert.Equal("Timeout", result.GetProperty("payload").GetProperty("failureReason").GetString());
    }

    [Fact]
    public async Task ReportHandledMediaPlaybackActionAsync_ValidatesAndDefaultsFailureReason()
    {
        var service = CreateService();
        await service.HandleMediaPlaybackPostedAsync(
            CreatePlayback(_identityManager.GetDeviceId(), "playback-1", "Track"),
            CancellationToken.None);
        await service.HandleMediaPlaybackActionRequestAsync(new MediaPlaybackActionRequestRecord
        {
            PlaybackId = "playback-1",
            SourceDeviceId = _identityManager.GetDeviceId(),
            RequestingDeviceId = "rift-peer",
            Action = "pause"
        }, CancellationToken.None);
        var notification = Assert.Single(_ipcNotificationService.Events, evt => evt.Method == "rift.onMediaPlaybackActionRequest");
        var requestId = JsonSerializer.SerializeToElement(notification.Payload).GetProperty("requestId").GetString()!;

        var invalid = await Assert.ThrowsAsync<MediaPlaybackSyncFailureException>(() =>
            service.ReportHandledMediaPlaybackActionAsync(requestId, true, "not-allowed", null, CancellationToken.None));
        Assert.Equal(-32602, invalid.ErrorCode);

        await service.ReportHandledMediaPlaybackActionAsync(requestId, false, null, null, CancellationToken.None);
        var result = Assert.Single(_transport.Payloads, payload =>
            payload.GetProperty("type").GetString() == "media.playbackActionResult");
        Assert.Equal("PeerRejected", result.GetProperty("payload").GetProperty("failureReason").GetString());
    }

    [Fact]
    public async Task HandleMediaPlaybackActionResultAsync_ValidatesAndDefaultsFailureReason()
    {
        const string peerDeviceId = "rift-peer";
        var service = CreateService();
        _presenceService.UpdatePeerPresence(peerDeviceId, "online", DateTimeOffset.UtcNow.ToString("O"), ["media.playback"]);
        await service.HandleMediaPlaybackPostedAsync(CreatePlayback(peerDeviceId, "playback-1", "Track"), CancellationToken.None);

        var rejected = await service.PerformMediaPlaybackActionAsync(peerDeviceId, "playback-1", "pause", null, CancellationToken.None);
        await service.HandleMediaPlaybackActionResultAsync(new MediaPlaybackActionResultRecord
        {
            PlaybackId = "playback-1",
            SourceDeviceId = peerDeviceId,
            RequestingDeviceId = _identityManager.GetDeviceId(),
            Action = "pause",
            Success = false
        }, CancellationToken.None);
        Assert.Equal("PeerRejected", _operationService.GetOperation(rejected.OperationId).FailureReason);

        var pending = await service.PerformMediaPlaybackActionAsync(peerDeviceId, "playback-1", "play", null, CancellationToken.None);
        var invalid = await Assert.ThrowsAsync<MediaPlaybackSyncFailureException>(() =>
            service.HandleMediaPlaybackActionResultAsync(new MediaPlaybackActionResultRecord
            {
                PlaybackId = "playback-1",
                SourceDeviceId = peerDeviceId,
                RequestingDeviceId = _identityManager.GetDeviceId(),
                Action = "play",
                Success = true,
                FailureReason = "not-allowed"
            }, CancellationToken.None));
        Assert.Equal(-32010, invalid.ErrorCode);
        await service.HandleMediaPlaybackActionResultAsync(new MediaPlaybackActionResultRecord
        {
            PlaybackId = "playback-1",
            SourceDeviceId = peerDeviceId,
            RequestingDeviceId = _identityManager.GetDeviceId(),
            Action = "play",
            Success = true
        }, CancellationToken.None);
        Assert.Equal("Done", _operationService.GetOperation(pending.OperationId).State);
    }

    [Theory]
    [InlineData("removed", "2026-07-16")]
    [InlineData("removed", "2026-07-16T10:00:00")]
    public async Task HandleLocalPlaybackEventAsync_RejectsMalformedRemovedAt(string eventType, string removedAt)
    {
        var service = CreateService();

        var error = await Assert.ThrowsAsync<MediaPlaybackSyncFailureException>(() =>
            service.HandleLocalPlaybackEventAsync(
                eventType,
                new MediaPlaybackRecord { PlaybackId = "playback-1" },
                removedAt,
                CancellationToken.None));

        Assert.Equal(-32602, error.ErrorCode);
    }

    [Fact]
    public async Task PeerSessionOnline_ReplaysLocalPlayback()
    {
        var service = CreateService();
        await service.HandleMediaPlaybackPostedAsync(
            CreatePlayback(_identityManager.GetDeviceId(), "playback-1", "Track"),
            CancellationToken.None);

        _transport.RaiseSessionStateChanged(new SessionStateChangedEventArgs(
            "rift-peer",
            isOnline: true,
            selectedCapabilities: ["media.playback"],
            allowsProtectedTraffic: true));

        var sent = Assert.Single(_transport.SentMessages);
        Assert.Equal("rift-peer", sent.PeerDeviceId);
        Assert.Equal("media.playbackPosted", sent.Type);
    }

    [Fact]
    public async Task PeerSessionOffline_RemovesRemotePlaybackRecords()
    {
        var service = CreateService();
        await service.HandleMediaPlaybackPostedAsync(CreatePlayback("rift-peer", "playback-1", "Track"), CancellationToken.None);
        await service.HandleMediaPlaybackPostedAsync(CreatePlayback("rift-peer", "playback-2", "Track 2"), CancellationToken.None);

        _transport.RaiseSessionStateChanged(new SessionStateChangedEventArgs(
            "rift-peer",
            isOnline: false,
            selectedCapabilities: [],
            allowsProtectedTraffic: false));

        Assert.Empty((await service.ListMediaPlaybackAsync(CancellationToken.None)).Playbacks);
        Assert.Equal(2, _ipcNotificationService.Events.Count(evt => evt.Method == "rift.onMediaPlaybackRemoved"));
    }

    [Fact]
    public async Task HandleMediaPlaybackPostedAsync_NormalizesJsonElementArtworkValues()
    {
        var service = CreateService();
        var artwork = JsonSerializer.Deserialize<Dictionary<string, object?>>(
            """{"dataBase64":"aW1hZ2U=","mediaType":"image/jpeg"}""")!;
        Assert.IsType<JsonElement>(artwork["dataBase64"]);

        await service.HandleMediaPlaybackPostedAsync(new MediaPlaybackRecord
        {
            PlaybackId = "playback-1",
            SourceDeviceId = "rift-peer",
            SourcePlatform = "macos",
            AppId = "com.example.browser",
            AppName = "Example Browser",
            Artwork = artwork,
            PlaybackState = "playing",
            PositionMs = 1000,
            CanPause = true,
            UpdatedAt = "2026-07-16T10:00:00Z"
        }, CancellationToken.None);

        var playback = Assert.Single((await service.ListMediaPlaybackAsync(CancellationToken.None)).Playbacks);
        Assert.Equal("aW1hZ2U=", Assert.IsType<string>(playback.Artwork!["dataBase64"]));
        Assert.Equal("image/jpeg", Assert.IsType<string>(playback.Artwork["mediaType"]));
    }

    [Theory]
    [InlineData("2026-07-16")]
    [InlineData("2026-07-16T10:00:00")]
    [InlineData("2026-07-16T10:00:00+01:00")]
    [InlineData("2026-02-30T10:00:00Z")]
    [InlineData("07/16/2026")]
    public async Task HandleMediaPlaybackPostedAsync_RejectsNonUtcRfc3339Timestamp(string updatedAt)
    {
        var service = CreateService();
        var playback = CreatePlayback("rift-peer", "playback-1", "Track");
        playback = new MediaPlaybackRecord
        {
            PlaybackId = playback.PlaybackId,
            SourceDeviceId = playback.SourceDeviceId,
            AppId = playback.AppId,
            AppName = playback.AppName,
            PlaybackState = playback.PlaybackState,
            PositionMs = playback.PositionMs,
            CanPlay = playback.CanPlay,
            CanPause = playback.CanPause,
            CanSkipNext = playback.CanSkipNext,
            CanSkipPrevious = playback.CanSkipPrevious,
            CanSeek = playback.CanSeek,
            UpdatedAt = updatedAt
        };

        await Assert.ThrowsAsync<InvalidOperationException>(() =>
            service.HandleMediaPlaybackPostedAsync(playback, CancellationToken.None));
    }

    [Fact]
    public async Task HandleMediaPlaybackPostedAsync_AcceptsExplicitZeroOffset()
    {
        var service = CreateService();
        var playback = new MediaPlaybackRecord
        {
            PlaybackId = "playback-1",
            SourceDeviceId = "rift-peer",
            AppId = "com.example.music",
            AppName = "Example Music",
            PlaybackState = "playing",
            PositionMs = 1000,
            UpdatedAt = "2026-07-16T10:00:00+00:00"
        };

        await service.HandleMediaPlaybackPostedAsync(playback, CancellationToken.None);
        Assert.Equal("playback-1", (await service.GetMediaPlaybackAsync("rift-peer", "playback-1", CancellationToken.None)).PlaybackId);
    }

    [Fact]
    public async Task PublishLocalPlaybackToPeerAsync_NormalizesLargeArtwork()
    {
        using var source = new SKBitmap(2048, 2048);
        using (var canvas = new SKCanvas(source))
        {
            canvas.Clear(SKColors.CornflowerBlue);
        }
        using var image = SKImage.FromBitmap(source);
        using var encodedSource = image.Encode(SKEncodedImageFormat.Png, 100);
        var playback = CreatePlayback(
            string.Empty,
            "playback-large-artwork",
            "Large Artwork",
            new Dictionary<string, object?>
            {
                ["dataBase64"] = Convert.ToBase64String(encodedSource.ToArray()),
                ["mediaType"] = "image/png"
            });
        var service = CreateService();

        await service.PublishLocalPlaybackToPeerAsync(
            "rift-new-peer",
            playback,
            CancellationToken.None);

        var payload = Assert.Single(_transport.Payloads);
        var artwork = payload.GetProperty("payload").GetProperty("artwork");
        Assert.Equal("image/jpeg", artwork.GetProperty("mediaType").GetString());
        var normalizedBytes = Convert.FromBase64String(artwork.GetProperty("dataBase64").GetString()!);
        Assert.InRange(normalizedBytes.Length, 1, 2 * 1024 * 1024);
        using var normalized = SKBitmap.Decode(normalizedBytes);
        Assert.NotNull(normalized);
        Assert.InRange(normalized!.Width, 1, 1024);
        Assert.InRange(normalized.Height, 1, 1024);
    }

    [Fact]
    public async Task PublishLocalPlaybackToPeerAsync_SendsDirectlyWithoutPresenceEntry()
    {
        var service = CreateService();

        await service.PublishLocalPlaybackToPeerAsync(
            "rift-new-peer",
            CreatePlayback(string.Empty, "playback-1", "Paused Track"),
            CancellationToken.None);

        var sent = Assert.Single(_transport.SentMessages);
        Assert.Equal("rift-new-peer", sent.PeerDeviceId);
        Assert.Equal("media.playbackPosted", sent.Type);
    }

    [Fact]
    public async Task PerformMediaPlaybackActionAsync_RejectsDuplicateAndExpiresLostResult()
    {
        const string peerDeviceId = "rift-peer";
        // Wide enough that the duplicate request below always lands inside the
        // pending window, even on slow CI machines.
        var service = CreateService(actionTimeout: TimeSpan.FromMilliseconds(500));
        _presenceService.UpdatePeerPresence(peerDeviceId, "online", DateTimeOffset.UtcNow.ToString("O"), ["media.playback"]);
        await service.HandleMediaPlaybackPostedAsync(CreatePlayback(peerDeviceId, "playback-1", "Track"), CancellationToken.None);

        var first = await service.PerformMediaPlaybackActionAsync(peerDeviceId, "playback-1", "pause", null, CancellationToken.None);
        var actionRequest = Assert.Single(_transport.Payloads, payload =>
            payload.GetProperty("type").GetString() == "media.playbackActionRequest");
        Assert.False(actionRequest.GetProperty("payload").TryGetProperty("positionMs", out _));
        var duplicate = await Assert.ThrowsAsync<MediaPlaybackSyncFailureException>(() =>
            service.PerformMediaPlaybackActionAsync(peerDeviceId, "playback-1", "pause", null, CancellationToken.None));
        Assert.Equal(-32010, duplicate.ErrorCode);

        var deadline = DateTime.UtcNow.AddSeconds(5);
        while (_operationService.GetOperation(first.OperationId).State != "Expired" && DateTime.UtcNow < deadline)
        {
            await Task.Delay(20);
        }
        var expired = _operationService.GetOperation(first.OperationId);
        Assert.Equal("Expired", expired.State);
        Assert.Equal("Timeout", expired.FailureReason);

        var retry = await service.PerformMediaPlaybackActionAsync(peerDeviceId, "playback-1", "pause", null, CancellationToken.None);
        await service.HandleMediaPlaybackActionResultAsync(new MediaPlaybackActionResultRecord
        {
            PlaybackId = "playback-1",
            SourceDeviceId = peerDeviceId,
            RequestingDeviceId = _identityManager.GetDeviceId(),
            Action = "pause",
            Success = true
        }, CancellationToken.None);
        Assert.Equal("Done", _operationService.GetOperation(retry.OperationId).State);
    }

    [Fact]
    public async Task GetMediaPlaybackAsync_QualifiesPlaybackIdBySourceDevice()
    {
        var service = new MediaPlaybackSyncService(
            _transport,
            _presenceService,
            _identityManager,
            _operationService,
            _securityEventLog,
            _ipcNotificationService,
            logger: NullLogger<MediaPlaybackSyncService>.Instance);
        await service.HandleMediaPlaybackPostedAsync(CreatePlayback("rift-source-a", "shared-playback", "Track A"), CancellationToken.None);
        await service.HandleMediaPlaybackPostedAsync(CreatePlayback("rift-source-b", "shared-playback", "Track B"), CancellationToken.None);

        var result = await service.GetMediaPlaybackAsync("rift-source-b", "shared-playback", CancellationToken.None);

        Assert.Equal("rift-source-b", result.SourceDeviceId);
        Assert.Equal("Track B", result.Title);
    }

    private MediaPlaybackSyncService CreateService(TimeSpan? actionTimeout = null) => new(
        _transport,
        _presenceService,
        _identityManager,
        _operationService,
        _securityEventLog,
        _ipcNotificationService,
        logger: NullLogger<MediaPlaybackSyncService>.Instance,
        actionTimeout: actionTimeout);

    private static MediaPlaybackRecord CreatePlayback(
        string sourceDeviceId,
        string playbackId,
        string title,
        IReadOnlyDictionary<string, object?>? artwork = null) => new()
    {
        PlaybackId = playbackId,
        SourceDeviceId = sourceDeviceId,
        AppId = "com.example.music",
        AppName = "Example Music",
        Title = title,
        Artwork = artwork,
        PlaybackState = "playing",
        PositionMs = 1000,
        CanPlay = true,
        CanPause = true,
        CanSkipNext = true,
        CanSkipPrevious = true,
        CanSeek = true,
        UpdatedAt = "2026-07-16T10:00:00Z"
    };

    public void Dispose()
    {
        SqliteConnection.ClearAllPools();
        if (File.Exists(_databasePath))
        {
            File.Delete(_databasePath);
        }
    }

    private sealed class RecordingLocalMediaPlaybackActionHandler : ILocalMediaPlaybackActionHandler
    {
        public List<PendingIncomingMediaPlaybackAction> Requests { get; } = [];
        public LocalMediaPlaybackActionResult Result { get; set; } = new() { Success = true };

        public Task<LocalMediaPlaybackActionResult> HandleActionAsync(PendingIncomingMediaPlaybackAction request, CancellationToken cancellationToken)
        {
            Requests.Add(request);
            return Task.FromResult(Result);
        }
    }

    private sealed class RecordingTransport : ITransport
    {
        public event EventHandler<MessageReceivedEventArgs>? MessageReceived
        {
            add { }
            remove { }
        }

        public event EventHandler<SessionStateChangedEventArgs>? SessionStateChanged;

        public void RaiseSessionStateChanged(SessionStateChangedEventArgs args) =>
            SessionStateChanged?.Invoke(this, args);

        public List<(string PeerDeviceId, string Type)> SentMessages { get; } = [];
        public List<JsonElement> Payloads { get; } = [];

        public Task StartListeningAsync(CancellationToken cancellationToken) => Task.CompletedTask;

        public Task ConnectToPeerAsync(string host, int port, CancellationToken cancellationToken) => Task.CompletedTask;

        public Task<string> ConnectToPeerWithIdentityAsync(string host, int port, CancellationToken cancellationToken) =>
            Task.FromResult("rift-peer");

        public bool HasActiveSession(string peerDeviceId) => true;

        public bool HasProtectedSession(string peerDeviceId) => true;

        public void RefreshSessionAuthorization(string peerDeviceId)
        {
        }

        public PeerSessionEndpoint? GetPeerSessionEndpoint(string peerDeviceId) => null;

        public Task SendAsync(string peerDeviceId, ReadOnlyMemory<byte> frameBody, CancellationToken cancellationToken)
        {
            using var document = JsonDocument.Parse(frameBody);
            SentMessages.Add((peerDeviceId, document.RootElement.GetProperty("type").GetString() ?? string.Empty));
            Payloads.Add(document.RootElement.Clone());
            return Task.CompletedTask;
        }

        public Task DisconnectPeerAsync(string peerDeviceId, CancellationToken cancellationToken) => Task.CompletedTask;
    }

    private sealed class RecordingIpcNotificationService : IIpcNotificationService
    {
        public List<(string Method, object Payload)> Events { get; } = [];

        public IDisposable RegisterClient(JsonRpc jsonRpc) => NullDisposable.Instance;

        public Task NotifyAsync(string method, object parameters, CancellationToken cancellationToken = default)
        {
            Events.Add((method, parameters));
            return Task.CompletedTask;
        }

        private sealed class NullDisposable : IDisposable
        {
            public static readonly NullDisposable Instance = new();

            public void Dispose()
            {
            }
        }
    }
}
