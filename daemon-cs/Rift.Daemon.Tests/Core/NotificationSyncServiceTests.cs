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

public sealed class NotificationSyncServiceTests : IDisposable
{
    private readonly string _databasePath;
    private readonly DatabaseContext _databaseContext;
    private readonly SqliteSecurityEventLog _securityEventLog;
    private readonly IdentityManager _identityManager;
    private readonly PresenceService _presenceService;
    private readonly RecordingTransport _transport;
    private readonly RecordingIpcNotificationService _ipcNotificationService;
    private readonly OperationService _operationService;
    private readonly NotificationSyncService _service;

    public NotificationSyncServiceTests()
    {
        _databasePath = Path.Combine(Path.GetTempPath(), $"rift-notification-sync-{Guid.NewGuid():N}.db");
        _databaseContext = new DatabaseContext(_databasePath);
        _databaseContext.Initialize();
        _securityEventLog = new SqliteSecurityEventLog(_databaseContext);
        _identityManager = new IdentityManager(new SqliteLocalIdentityStore(_databaseContext));
        _presenceService = new PresenceService();
        _transport = new RecordingTransport();
        _ipcNotificationService = new RecordingIpcNotificationService();
        _operationService = new OperationService(_ipcNotificationService, _securityEventLog, _identityManager, NullLogger<OperationService>.Instance);
        _service = new NotificationSyncService(
            _transport,
            _presenceService,
            _identityManager,
            _operationService,
            _securityEventLog,
            _ipcNotificationService,
            NullLogger<NotificationSyncService>.Instance);
    }

    [Fact]
    public async Task HandleNotificationPostedAsync_ListNotificationsReturnsMirroredInbox()
    {
        await _service.HandleNotificationPostedAsync(CreateNotification("notif-1", title: "Hello"), CancellationToken.None);

        var result = await _service.ListNotificationsAsync(CancellationToken.None);

        var notification = Assert.Single(result.Notifications);
        Assert.Equal("notif-1", notification.NotificationId);
        Assert.Equal("Hello", notification.Title);
        Assert.Contains(_ipcNotificationService.Events, evt => evt.Method == "rift.onNotificationPosted");
    }

    [Fact]
    public async Task HandleNotificationUpdatedAsync_ReplacesExistingMirroredRecord()
    {
        await _service.HandleNotificationPostedAsync(CreateNotification("notif-1", title: "Old"), CancellationToken.None);

        await _service.HandleNotificationUpdatedAsync(CreateNotification("notif-1", title: "New", bodyPreview: "Updated"), CancellationToken.None);

        var result = await _service.ListNotificationsAsync(CancellationToken.None);
        var notification = Assert.Single(result.Notifications);
        Assert.Equal("New", notification.Title);
        Assert.Equal("Updated", notification.BodyPreview);
        Assert.Contains(_ipcNotificationService.Events, evt => evt.Method == "rift.onNotificationUpdated");
    }

    [Fact]
    public async Task HandleNotificationRemovedAsync_HidesRemovedNotificationFromInbox()
    {
        await _service.HandleNotificationPostedAsync(CreateNotification("notif-1"), CancellationToken.None);

        await _service.HandleNotificationRemovedAsync(new NotificationRemovedRecord
        {
            NotificationId = "notif-1",
            SourceDeviceId = "rift-peer",
            RemovedAt = "2026-07-14T10:05:00Z"
        }, CancellationToken.None);

        var result = await _service.ListNotificationsAsync(CancellationToken.None);
        Assert.Empty(result.Notifications);
        Assert.Contains(_ipcNotificationService.Events, evt => evt.Method == "rift.onNotificationRemoved");
    }

    [Fact]
    public async Task PerformNotificationActionAsync_SendsActionRequestAndCompletesOperation()
    {
        _presenceService.UpdatePeerPresence("rift-peer", "online", null, ["notification.sync"]);
        _transport.ActivePeers.Add("rift-peer");
        await _service.HandleNotificationPostedAsync(CreateNotification("notif-1", isOpenable: true), CancellationToken.None);

        var result = await _service.PerformNotificationActionAsync("notif-1", "open", CancellationToken.None);

        Assert.Equal("notif-1", result.NotificationId);
        Assert.Contains(_transport.SentMessages, sent => sent.PeerDeviceId == "rift-peer" && sent.Type == "notification.actionRequest");

        await _service.HandleNotificationActionResultAsync(new NotificationActionResultRecord
        {
            NotificationId = "notif-1",
            SourceDeviceId = "rift-peer",
            RequestingDeviceId = _identityManager.GetDeviceId(),
            Action = "open",
            Success = true
        }, CancellationToken.None);

        var operation = _operationService.GetOperation(result.OperationId);
        Assert.Equal("Done", operation.State);
        Assert.Contains(_ipcNotificationService.Events, evt => evt.Method == "rift.onNotificationActionResult");
    }

    [Fact]
    public async Task PerformNotificationActionAsync_RejectsWhenPeerLacksCapability()
    {
        _presenceService.UpdatePeerPresence("rift-peer", "online", null, ["presence.basic"]);
        _transport.ActivePeers.Add("rift-peer");
        await _service.HandleNotificationPostedAsync(CreateNotification("notif-1", isDismissible: true), CancellationToken.None);

        var ex = await Assert.ThrowsAsync<NotificationSyncFailureException>(() =>
            _service.PerformNotificationActionAsync("notif-1", "dismiss", CancellationToken.None));

        Assert.Equal(-32003, ex.ErrorCode);
    }

    [Fact]
    public async Task PerformNotificationActionAsync_RegistersPendingActionBeforeSendCompletes()
    {
        var delayedTransport = new DelayedRecordingTransport();
        var service = new NotificationSyncService(
            delayedTransport,
            _presenceService,
            _identityManager,
            _operationService,
            _securityEventLog,
            _ipcNotificationService,
            NullLogger<NotificationSyncService>.Instance);
        _presenceService.UpdatePeerPresence("rift-peer", "online", null, ["notification.sync"]);
        delayedTransport.ActivePeers.Add("rift-peer");
        await service.HandleNotificationPostedAsync(CreateNotification("notif-race", isOpenable: true), CancellationToken.None);

        var actionTask = service.PerformNotificationActionAsync("notif-race", "open", CancellationToken.None);
        await delayedTransport.WaitForSendStartedAsync();
        await service.HandleNotificationActionResultAsync(new NotificationActionResultRecord
        {
            NotificationId = "notif-race",
            SourceDeviceId = "rift-peer",
            RequestingDeviceId = _identityManager.GetDeviceId(),
            Action = "open",
            Success = true
        }, CancellationToken.None);
        var pendingAction = await actionTask.WaitAsync(TimeSpan.FromSeconds(1));

        var operation = _operationService.GetOperation(pendingAction.OperationId);
        Assert.Equal("Done", operation.State);
    }

    [Fact]
    public async Task HandleLocalNotificationEventAsync_BroadcastsToTrustedPeers()
    {
        _presenceService.UpdatePeerPresence("rift-peer", "online", null, ["notification.sync"]);
        _transport.ActivePeers.Add("rift-peer");

        var result = await _service.HandleLocalNotificationEventAsync(
            "posted",
            new NotificationSyncRecord
            {
                NotificationId = "desktop-test-1",
                SourceDeviceId = _identityManager.GetDeviceId(),
                SourcePlatform = "windows",
                PackageName = "dev.rift.desktop",
                AppName = "Rift Desktop",
                Title = "Desktop test",
                BodyPreview = "Hello peers",
                PostedAt = "2026-07-16T10:00:00Z",
                IsDismissible = false,
                IsOpenable = false
            },
            null,
            CancellationToken.None);

        Assert.Equal("desktop-test-1", result.NotificationId);
        Assert.False(result.Suppressed);
        Assert.Contains("rift-peer", result.BroadcastTo);
        Assert.Contains(_transport.SentMessages, sent => sent.PeerDeviceId == "rift-peer" && sent.Type == "notification.posted");
        var payload = Assert.Single(
            _transport.Payloads,
            sent => sent.PeerDeviceId == "rift-peer" && sent.Type == "notification.posted");
        Assert.True(payload.Payload.TryGetProperty("notificationId", out _));
        Assert.False(payload.Payload.TryGetProperty("NotificationId", out _));
    }

    [Fact]
    public async Task HandleLocalNotificationEventAsync_DoesNotStoreOrBroadcastSuppressedNotifications()
    {
        await _service.UpdateNotificationSyncPolicyAsync(
            enabled: true,
            blacklistedPackages: ["dev.rift.desktop"],
            cancellationToken: CancellationToken.None);

        var result = await _service.HandleLocalNotificationEventAsync(
            "posted",
            new NotificationSyncRecord
            {
                NotificationId = "desktop-suppressed-1",
                SourceDeviceId = _identityManager.GetDeviceId(),
                SourcePlatform = "windows",
                PackageName = "dev.rift.desktop",
                AppName = "Rift Desktop",
                Title = "Desktop test",
                BodyPreview = "Should stay local",
                PostedAt = "2026-07-16T10:00:00Z",
                IsDismissible = false,
                IsOpenable = false
            },
            null,
            CancellationToken.None);

        var notifications = await _service.ListNotificationsAsync(CancellationToken.None);

        Assert.True(result.Suppressed);
        Assert.Empty(result.BroadcastTo);
        Assert.Empty(notifications.Notifications);
        Assert.DoesNotContain(_ipcNotificationService.Events, evt => evt.Method == "rift.onNotificationPosted");
    }

    [Fact]
    public async Task NotificationPolicy_LoadsAndPersistsThroughStore()
    {
        var store = new RecordingNotificationSyncPolicyStore
        {
            StoredPolicy = new NotificationSyncPolicy
            {
                Enabled = false,
                BlacklistedPackages = ["org.example.Secret"]
            }
        };
        var service = new NotificationSyncService(
            _transport,
            _presenceService,
            _identityManager,
            _operationService,
            _securityEventLog,
            _ipcNotificationService,
            NullLogger<NotificationSyncService>.Instance,
            store);

        var initial = await service.ListNotificationsAsync(CancellationToken.None);
        await service.UpdateNotificationSyncPolicyAsync(
            enabled: true,
            blacklistedPackages: [" org.example.Chat ", "org.example.Chat"],
            cancellationToken: CancellationToken.None);

        Assert.False(initial.Policy.Enabled);
        Assert.Equal(["org.example.Secret"], initial.Policy.BlacklistedPackages);
        Assert.NotNull(store.StoredPolicy);
        Assert.True(store.StoredPolicy.Enabled);
        Assert.Equal(["org.example.Chat"], store.StoredPolicy.BlacklistedPackages);
    }

    [Fact]
    public async Task NotificationPolicy_UpdateRollsBackAndPropagatesWhenPersistenceFails()
    {
        var store = new RecordingNotificationSyncPolicyStore
        {
            StoredPolicy = new NotificationSyncPolicy
            {
                Enabled = true,
                BlacklistedPackages = ["org.example.Secret"]
            },
            SaveException = new IOException("database is read-only")
        };
        var service = new NotificationSyncService(
            _transport,
            _presenceService,
            _identityManager,
            _operationService,
            _securityEventLog,
            _ipcNotificationService,
            NullLogger<NotificationSyncService>.Instance,
            store);

        var exception = await Assert.ThrowsAsync<IOException>(() =>
            service.UpdateNotificationSyncPolicyAsync(
                enabled: false,
                blacklistedPackages: ["org.example.Chat"],
                cancellationToken: CancellationToken.None));
        var current = await service.ListNotificationsAsync(CancellationToken.None);

        Assert.Equal("database is read-only", exception.Message);
        Assert.True(current.Policy.Enabled);
        Assert.Equal(["org.example.Secret"], current.Policy.BlacklistedPackages);
    }

    public void Dispose()
    {
        SqliteConnection.ClearAllPools();
        if (File.Exists(_databasePath))
        {
            File.Delete(_databasePath);
        }
    }

    private static NotificationSyncRecord CreateNotification(
        string notificationId,
        string? title = "Title",
        string? bodyPreview = "Body",
        bool isDismissible = true,
        bool isOpenable = false)
    {
        return new NotificationSyncRecord
        {
            NotificationId = notificationId,
            SourceDeviceId = "rift-peer",
            PackageName = "com.example.chat",
            AppName = "Example Chat",
            Title = title,
            BodyPreview = bodyPreview,
            PostedAt = "2026-07-14T10:00:00Z",
            IsDismissible = isDismissible,
            IsOpenable = isOpenable
        };
    }

    private sealed class RecordingNotificationSyncPolicyStore : INotificationSyncPolicyStore
    {
        public NotificationSyncPolicy StoredPolicy { get; set; } = new()
        {
            Enabled = true,
            BlacklistedPackages = []
        };

        public Exception? SaveException { get; init; }

        public NotificationSyncPolicy Load() => new()
        {
            Enabled = StoredPolicy.Enabled,
            BlacklistedPackages = StoredPolicy.BlacklistedPackages.ToArray()
        };

        public void Save(NotificationSyncPolicy policy)
        {
            if (SaveException is not null)
            {
                throw SaveException;
            }

            StoredPolicy = new NotificationSyncPolicy
            {
                Enabled = policy.Enabled,
                BlacklistedPackages = policy.BlacklistedPackages.ToArray()
            };
        }
    }

    private class RecordingTransport : ITransport
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

        public HashSet<string> ActivePeers { get; } = new(StringComparer.Ordinal);
        public List<(string PeerDeviceId, string Type)> SentMessages { get; } = [];
        public List<(string PeerDeviceId, string Type, JsonElement Payload)> Payloads { get; } = [];

        public Task StartListeningAsync(CancellationToken cancellationToken) => Task.CompletedTask;

        public Task ConnectToPeerAsync(string host, int port, CancellationToken cancellationToken) => Task.CompletedTask;

        public Task<string> ConnectToPeerWithIdentityAsync(string host, int port, CancellationToken cancellationToken, string? expectedDeviceId = null) =>
            Task.FromResult("rift-peer");

        public bool HasActiveSession(string peerDeviceId) => ActivePeers.Contains(peerDeviceId);
        public bool HasProtectedSession(string peerDeviceId) => ActivePeers.Contains(peerDeviceId);
        public void RefreshSessionAuthorization(string peerDeviceId) { }

        public PeerSessionEndpoint? GetPeerSessionEndpoint(string peerDeviceId) => null;

        public virtual Task SendAsync(string peerDeviceId, ReadOnlyMemory<byte> frameBody, CancellationToken cancellationToken)
        {
            using var document = JsonDocument.Parse(frameBody);
            var type = document.RootElement.GetProperty("type").GetString() ?? string.Empty;
            SentMessages.Add((peerDeviceId, type));
            Payloads.Add((peerDeviceId, type, document.RootElement.GetProperty("payload").Clone()));
            return Task.CompletedTask;
        }

        public Task DisconnectPeerAsync(string peerDeviceId, CancellationToken cancellationToken) => Task.CompletedTask;
    }

    private sealed class DelayedRecordingTransport : RecordingTransport
    {
        private readonly TaskCompletionSource _sendStarted =
            new(TaskCreationOptions.RunContinuationsAsynchronously);

        public override async Task SendAsync(
            string peerDeviceId,
            ReadOnlyMemory<byte> frameBody,
            CancellationToken cancellationToken)
        {
            using var document = JsonDocument.Parse(frameBody);
            var type = document.RootElement.GetProperty("type").GetString() ?? string.Empty;
            SentMessages.Add((peerDeviceId, type));
            Payloads.Add((peerDeviceId, type, document.RootElement.GetProperty("payload").Clone()));
            _sendStarted.TrySetResult();
            await Task.Delay(50, cancellationToken);
        }

        public Task WaitForSendStartedAsync() => _sendStarted.Task;
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
