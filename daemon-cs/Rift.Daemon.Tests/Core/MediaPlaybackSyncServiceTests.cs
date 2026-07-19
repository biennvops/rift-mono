using System.Text;
using System.Text.Json;
using Microsoft.Data.Sqlite;
using Microsoft.Extensions.Logging.Abstractions;
using Rift.Daemon.Core;
using Rift.Daemon.Core.Cryptography;
using Rift.Daemon.Core.Data;
using Rift.Daemon.Core.Interfaces;
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

    private static MediaPlaybackRecord CreatePlayback(string sourceDeviceId, string playbackId, string title) => new()
    {
        PlaybackId = playbackId,
        SourceDeviceId = sourceDeviceId,
        AppId = "com.example.music",
        AppName = "Example Music",
        Title = title,
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

        public event EventHandler<SessionStateChangedEventArgs>? SessionStateChanged
        {
            add { }
            remove { }
        }

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
