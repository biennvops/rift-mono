using System.Reflection;
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
    public async Task NotificationIcon_SurvivesStorageIpcAndBroadcast()
    {
        _presenceService.UpdatePeerPresence("rift-peer", "online", null, ["notification.sync"]);
        _transport.ActivePeers.Add("rift-peer");
        var icon = CreateIcon();

        await _service.HandleLocalNotificationEventAsync(
            "posted",
            CreateNotification(
                "notif-icon",
                sourceDeviceId: _identityManager.GetDeviceId(),
                icon: icon),
            null,
            CancellationToken.None);

        var listed = await _service.ListNotificationsAsync(CancellationToken.None);
        Assert.Equal(icon, Assert.Single(listed.Notifications).Icon);
        var ipcNotification = Assert.IsType<NotificationSyncRecord>(
            Assert.Single(_ipcNotificationService.Events, evt => evt.Method == "rift.onNotificationPosted").Payload);
        Assert.Equal(icon, ipcNotification.Icon);
        var broadcast = Assert.Single(_transport.Payloads, sent => sent.Type == "notification.posted");
        Assert.Equal("image/png", broadcast.Payload.GetProperty("icon").GetProperty("mediaType").GetString());
    }

    [Fact]
    public async Task MalformedNotificationIcon_IsDroppedWithoutDroppingNotification()
    {
        var icon = CreateIcon();
        icon["sha256"] = new string('0', 64);

        await _service.HandleNotificationPostedAsync(
            CreateNotification("notif-invalid-icon", icon: icon),
            CancellationToken.None);

        var listed = await _service.ListNotificationsAsync(CancellationToken.None);
        Assert.Null(Assert.Single(listed.Notifications).Icon);
    }

    [Fact]
    public async Task HandleNotificationRemovedAsync_DeletesIconBearingRecordFromMemory()
    {
        await _service.HandleNotificationPostedAsync(
            CreateNotification("notif-icon-removed", icon: CreateIcon()),
            CancellationToken.None);

        await _service.HandleNotificationRemovedAsync(new NotificationRemovedRecord
        {
            NotificationId = "notif-icon-removed",
            SourceDeviceId = "rift-peer"
        }, CancellationToken.None);

        var field = typeof(NotificationSyncService).GetField(
            "_notifications",
            BindingFlags.Instance | BindingFlags.NonPublic);
        var records = Assert.IsType<Dictionary<string, NotificationSyncRecord>>(
            field!.GetValue(_service));

        Assert.DoesNotContain("rift-peer\nnotif-icon-removed", records.Keys);
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

        var result = await _service.PerformNotificationActionAsync("rift-peer", "notif-1", "open", CancellationToken.None);

        Assert.Equal("notif-1", result.NotificationId);
        Assert.Equal("rift-peer", result.SourceDeviceId);
        Assert.Contains(_transport.SentMessages, sent => sent.PeerDeviceId == "rift-peer" && sent.Type == "notification.actionRequest");
        var requestPayload = Assert.Single(
            _transport.Payloads,
            sent => sent.Type == "notification.actionRequest").Payload;
        Assert.Equal(result.OperationId, requestPayload.GetProperty("operationId").GetString());
        Assert.Equal("notif-1", requestPayload.GetProperty("notificationId").GetString());
        Assert.Equal("rift-peer", requestPayload.GetProperty("sourceDeviceId").GetString());
        Assert.Equal(_identityManager.GetDeviceId(), requestPayload.GetProperty("requestingDeviceId").GetString());
        Assert.Equal("open", requestPayload.GetProperty("action").GetString());
        Assert.False(string.IsNullOrWhiteSpace(requestPayload.GetProperty("requestedAt").GetString()));

        await _service.HandleNotificationActionResultAsync(new NotificationActionResultRecord
        {
            OperationId = result.OperationId,
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
    public async Task PerformNotificationActionAsync_RejectsDuplicateAndExpiresLostResult()
    {
        var service = new NotificationSyncService(
            _transport,
            _presenceService,
            _identityManager,
            _operationService,
            _securityEventLog,
            _ipcNotificationService,
            NullLogger<NotificationSyncService>.Instance,
            actionTimeout: TimeSpan.FromMilliseconds(500));
        _presenceService.UpdatePeerPresence("rift-peer", "online", null, ["notification.sync"]);
        _transport.ActivePeers.Add("rift-peer");
        await service.HandleNotificationPostedAsync(CreateNotification("notif-1"), CancellationToken.None);

        var first = await service.PerformNotificationActionAsync(
            "rift-peer",
            "notif-1",
            "dismiss",
            CancellationToken.None);
        var duplicate = await Assert.ThrowsAsync<NotificationSyncFailureException>(() =>
            service.PerformNotificationActionAsync("rift-peer", "notif-1", "dismiss", CancellationToken.None));

        Assert.Equal(-32010, duplicate.ErrorCode);
        Assert.Equal("Dispatched", _operationService.GetOperation(first.OperationId).State);
        Assert.Single(_transport.SentMessages, sent => sent.Type == "notification.actionRequest");

        var deadline = DateTime.UtcNow.AddSeconds(5);
        while (_operationService.GetOperation(first.OperationId).State != "Expired" && DateTime.UtcNow < deadline)
        {
            await Task.Delay(20);
        }

        var expired = _operationService.GetOperation(first.OperationId);
        Assert.Equal("Expired", expired.State);
        Assert.Equal("Timeout", expired.FailureReason);

        var retry = await service.PerformNotificationActionAsync(
            "rift-peer",
            "notif-1",
            "dismiss",
            CancellationToken.None);
        await Assert.ThrowsAsync<InvalidOperationException>(() =>
            service.HandleNotificationActionResultAsync(
                CreateActionResult(operationId: first.OperationId),
                CancellationToken.None));
        Assert.Equal("Dispatched", _operationService.GetOperation(retry.OperationId).State);

        await service.HandleNotificationActionResultAsync(
            CreateActionResult(operationId: retry.OperationId),
            CancellationToken.None);
        Assert.Equal("Done", _operationService.GetOperation(retry.OperationId).State);
    }

    [Fact]
    public async Task PerformNotificationActionAsync_RejectsWhenPeerLacksCapability()
    {
        _presenceService.UpdatePeerPresence("rift-peer", "online", null, ["presence.basic"]);
        _transport.ActivePeers.Add("rift-peer");
        await _service.HandleNotificationPostedAsync(CreateNotification("notif-1", isDismissible: true), CancellationToken.None);

        var ex = await Assert.ThrowsAsync<NotificationSyncFailureException>(() =>
            _service.PerformNotificationActionAsync("rift-peer", "notif-1", "dismiss", CancellationToken.None));

        Assert.Equal(-32003, ex.ErrorCode);
    }

    [Fact]
    public async Task PerformNotificationActionAsync_TargetsExactSourceDeviceForSharedNotificationIds()
    {
        _presenceService.UpdatePeerPresence("rift-peer", "online", null, ["notification.sync"]);
        _presenceService.UpdatePeerPresence("rift-other", "online", null, ["notification.sync"]);
        _transport.ActivePeers.Add("rift-peer");
        _transport.ActivePeers.Add("rift-other");
        await _service.HandleNotificationPostedAsync(CreateNotification("shared-id"), CancellationToken.None);
        await _service.HandleNotificationPostedAsync(
            CreateNotification("shared-id", sourceDeviceId: "rift-other"),
            CancellationToken.None);

        var result = await _service.PerformNotificationActionAsync(
            "rift-other",
            "shared-id",
            "dismiss",
            CancellationToken.None);

        Assert.Equal("rift-other", result.SourceDeviceId);
        var request = Assert.Single(_transport.SentMessages, sent => sent.Type == "notification.actionRequest");
        Assert.Equal("rift-other", request.PeerDeviceId);
    }

    [Theory]
    [InlineData("", "notif-1")]
    [InlineData("   ", "notif-1")]
    [InlineData("rift-peer", "")]
    [InlineData("rift-peer", "   ")]
    public async Task PerformNotificationActionAsync_RequiresCompositeIdentity(string sourceDeviceId, string notificationId)
    {
        _presenceService.UpdatePeerPresence("rift-peer", "online", null, ["notification.sync"]);
        _transport.ActivePeers.Add("rift-peer");
        await _service.HandleNotificationPostedAsync(CreateNotification("notif-1"), CancellationToken.None);

        var ex = await Assert.ThrowsAsync<NotificationSyncFailureException>(() =>
            _service.PerformNotificationActionAsync(sourceDeviceId, notificationId, "dismiss", CancellationToken.None));

        Assert.Equal(-32009, ex.ErrorCode);
        Assert.DoesNotContain(_transport.SentMessages, sent => sent.Type == "notification.actionRequest");
    }

    [Fact]
    public async Task PerformNotificationActionAsync_RejectsUnknownCompositeIdentity()
    {
        _presenceService.UpdatePeerPresence("rift-peer", "online", null, ["notification.sync"]);
        _transport.ActivePeers.Add("rift-peer");
        await _service.HandleNotificationPostedAsync(CreateNotification("notif-1"), CancellationToken.None);

        var ex = await Assert.ThrowsAsync<NotificationSyncFailureException>(() =>
            _service.PerformNotificationActionAsync("rift-unknown", "notif-1", "dismiss", CancellationToken.None));

        Assert.Equal(-32009, ex.ErrorCode);
    }

    [Fact]
    public async Task PerformNotificationActionAsync_RejectsRemovedNotification()
    {
        _presenceService.UpdatePeerPresence("rift-peer", "online", null, ["notification.sync"]);
        _transport.ActivePeers.Add("rift-peer");
        await _service.HandleNotificationPostedAsync(CreateNotification("notif-1"), CancellationToken.None);
        await _service.HandleNotificationRemovedAsync(new NotificationRemovedRecord
        {
            NotificationId = "notif-1",
            SourceDeviceId = "rift-peer"
        }, CancellationToken.None);

        var ex = await Assert.ThrowsAsync<NotificationSyncFailureException>(() =>
            _service.PerformNotificationActionAsync("rift-peer", "notif-1", "dismiss", CancellationToken.None));

        Assert.Equal(-32009, ex.ErrorCode);
    }

    [Fact]
    public async Task PerformNotificationActionAsync_RejectsActionThatIsNotAdvertised()
    {
        _presenceService.UpdatePeerPresence("rift-peer", "online", null, ["notification.sync"]);
        _transport.ActivePeers.Add("rift-peer");
        await _service.HandleNotificationPostedAsync(
            CreateNotification("notif-1", isDismissible: false),
            CancellationToken.None);

        var ex = await Assert.ThrowsAsync<NotificationSyncFailureException>(() =>
            _service.PerformNotificationActionAsync("rift-peer", "notif-1", "dismiss", CancellationToken.None));

        Assert.Equal(-32010, ex.ErrorCode);
    }

    [Fact]
    public async Task HandleNotificationActionRequestAsync_UsesDirectHandlerAndPreservesCorrelation()
    {
        var localActionHandler = new RecordingLocalNotificationActionHandler();
        var service = CreateService(localActionHandler: localActionHandler);
        var localDeviceId = _identityManager.GetDeviceId();
        await service.HandleNotificationPostedAsync(
            CreateNotification("local-notif", sourceDeviceId: localDeviceId),
            CancellationToken.None);

        await service.HandleNotificationActionRequestAsync(
            CreateIncomingActionRequest("peer-operation", "local-notif"),
            CancellationToken.None);

        var handled = Assert.Single(localActionHandler.Performed);
        Assert.Equal("local-notif", handled.Notification.NotificationId);
        Assert.Equal("dismiss", handled.Action);
        Assert.DoesNotContain(
            _ipcNotificationService.Events,
            evt => evt.Method == "rift.onNotificationActionRequest");
        var result = Assert.Single(_transport.Payloads, sent => sent.Type == "notification.actionResult");
        Assert.Equal("rift-peer", result.PeerDeviceId);
        Assert.Equal("peer-operation", result.Payload.GetProperty("operationId").GetString());
        Assert.Equal("local-notif", result.Payload.GetProperty("notificationId").GetString());
        Assert.Equal(localDeviceId, result.Payload.GetProperty("sourceDeviceId").GetString());
        Assert.Equal("rift-peer", result.Payload.GetProperty("requestingDeviceId").GetString());
        Assert.Equal("dismiss", result.Payload.GetProperty("action").GetString());
        Assert.True(result.Payload.GetProperty("success").GetBoolean());
    }

    [Fact]
    public async Task HandleNotificationActionRequestAsync_ReportsDirectHandlerFailure()
    {
        var localActionHandler = new RecordingLocalNotificationActionHandler
        {
            Result = new LocalNotificationActionResult
            {
                Success = false,
                FailureReason = "CapabilityUnavailable",
                Message = "native target disappeared"
            }
        };
        var service = CreateService(localActionHandler: localActionHandler);
        await service.HandleNotificationPostedAsync(
            CreateNotification("local-notif", sourceDeviceId: _identityManager.GetDeviceId()),
            CancellationToken.None);

        await service.HandleNotificationActionRequestAsync(
            CreateIncomingActionRequest("peer-operation", "local-notif"),
            CancellationToken.None);

        var result = Assert.Single(_transport.Payloads, sent => sent.Type == "notification.actionResult").Payload;
        Assert.False(result.GetProperty("success").GetBoolean());
        Assert.Equal("CapabilityUnavailable", result.GetProperty("failureReason").GetString());
        Assert.Equal("native target disappeared", result.GetProperty("message").GetString());
    }

    [Fact]
    public async Task HandleNotificationActionRequestAsync_RejectsInvalidTargetsAndActionsBeforeExecution()
    {
        var localActionHandler = new RecordingLocalNotificationActionHandler();
        var service = CreateService(localActionHandler: localActionHandler);
        var localDeviceId = _identityManager.GetDeviceId();
        await service.HandleNotificationPostedAsync(
            CreateNotification("remote-only", sourceDeviceId: "rift-peer"),
            CancellationToken.None);
        await service.HandleNotificationPostedAsync(
            CreateNotification("restricted", isDismissible: false, sourceDeviceId: localDeviceId),
            CancellationToken.None);

        await service.HandleNotificationActionRequestAsync(
            CreateIncomingActionRequest("missing-operation", "missing"),
            CancellationToken.None);
        await service.HandleNotificationActionRequestAsync(
            CreateIncomingActionRequest("remote-operation", "remote-only"),
            CancellationToken.None);
        await service.HandleNotificationActionRequestAsync(
            CreateIncomingActionRequest("restricted-operation", "restricted"),
            CancellationToken.None);
        await service.HandleNotificationActionRequestAsync(
            CreateIncomingActionRequest("unknown-operation", "restricted", action: "reply"),
            CancellationToken.None);

        Assert.Empty(localActionHandler.Performed);
        var results = _transport.Payloads
            .Where(sent => sent.Type == "notification.actionResult")
            .Select(sent => sent.Payload)
            .ToArray();
        Assert.Equal(4, results.Length);
        Assert.Equal(
            2,
            results.Count(result =>
                result.GetProperty("failureReason").GetString() == "CapabilityUnavailable"));
        Assert.Contains(
            results,
            result => result.GetProperty("failureReason").GetString() == "PolicyDenied");
        Assert.Contains(
            results,
            result => result.GetProperty("failureReason").GetString() == "ProtocolError");
    }

    [Fact]
    public async Task HandleNotificationActionRequestAsync_FallsBackToIpcAndCompletesOnce()
    {
        var service = CreateService();
        var localDeviceId = _identityManager.GetDeviceId();
        await service.HandleNotificationPostedAsync(
            CreateNotification("local-notif", sourceDeviceId: localDeviceId),
            CancellationToken.None);

        await service.HandleNotificationActionRequestAsync(
            CreateIncomingActionRequest(
                "peer-operation",
                "local-notif",
                requestedAt: "2026-07-20T10:00:00Z"),
            CancellationToken.None);

        var notification = Assert.Single(
            _ipcNotificationService.Events,
            evt => evt.Method == "rift.onNotificationActionRequest");
        var payload = JsonSerializer.SerializeToElement(notification.Payload);
        var requestId = payload.GetProperty("requestId").GetString()!;
        Assert.NotEqual("peer-operation", requestId);
        Assert.Equal("peer-operation", payload.GetProperty("operationId").GetString());
        Assert.Equal(localDeviceId, payload.GetProperty("sourceDeviceId").GetString());
        Assert.Equal("rift-peer", payload.GetProperty("requestingDeviceId").GetString());
        Assert.Equal("2026-07-20T10:00:00Z", payload.GetProperty("requestedAt").GetString());

        var report = await service.ReportHandledNotificationActionAsync(
            requestId,
            success: true,
            failureReason: "PeerRejected",
            message: null,
            CancellationToken.None);

        Assert.Equal(requestId, report.RequestId);
        Assert.True(report.Success);
        var result = Assert.Single(_transport.Payloads, sent => sent.Type == "notification.actionResult").Payload;
        Assert.Equal("peer-operation", result.GetProperty("operationId").GetString());
        Assert.True(result.GetProperty("success").GetBoolean());
        Assert.Equal(JsonValueKind.Null, result.GetProperty("failureReason").ValueKind);
        var repeated = await Assert.ThrowsAsync<NotificationSyncFailureException>(() =>
            service.ReportHandledNotificationActionAsync(
                requestId,
                true,
                null,
                null,
                CancellationToken.None));
        Assert.Equal(-32009, repeated.ErrorCode);
    }

    [Fact]
    public async Task ReportHandledNotificationActionAsync_ValidatesAndDefaultsFailureReason()
    {
        var service = CreateService();
        await service.HandleNotificationPostedAsync(
            CreateNotification("local-notif", sourceDeviceId: _identityManager.GetDeviceId()),
            CancellationToken.None);
        await service.HandleNotificationActionRequestAsync(
            CreateIncomingActionRequest("peer-operation", "local-notif"),
            CancellationToken.None);
        var notification = Assert.Single(
            _ipcNotificationService.Events,
            evt => evt.Method == "rift.onNotificationActionRequest");
        var requestId = JsonSerializer.SerializeToElement(notification.Payload)
            .GetProperty("requestId")
            .GetString()!;

        var invalid = await Assert.ThrowsAsync<NotificationSyncFailureException>(() =>
            service.ReportHandledNotificationActionAsync(
                requestId,
                false,
                "not-allowed",
                null,
                CancellationToken.None));
        Assert.Equal(-32602, invalid.ErrorCode);

        await service.ReportHandledNotificationActionAsync(
            requestId,
            false,
            null,
            "native executor rejected the request",
            CancellationToken.None);
        var result = Assert.Single(_transport.Payloads, sent => sent.Type == "notification.actionResult").Payload;
        Assert.Equal("PeerRejected", result.GetProperty("failureReason").GetString());
        Assert.Equal("native executor rejected the request", result.GetProperty("message").GetString());
    }

    [Fact]
    public async Task HandleNotificationActionRequestAsync_ExpiresUnhandledIpcRequest()
    {
        var service = CreateService(actionTimeout: TimeSpan.FromMilliseconds(50));
        await service.HandleNotificationPostedAsync(
            CreateNotification("local-notif", sourceDeviceId: _identityManager.GetDeviceId()),
            CancellationToken.None);
        await service.HandleNotificationActionRequestAsync(
            CreateIncomingActionRequest("peer-operation", "local-notif"),
            CancellationToken.None);
        var notification = Assert.Single(
            _ipcNotificationService.Events,
            evt => evt.Method == "rift.onNotificationActionRequest");
        var requestId = JsonSerializer.SerializeToElement(notification.Payload)
            .GetProperty("requestId")
            .GetString()!;

        var deadline = DateTime.UtcNow.AddSeconds(5);
        while (!_transport.Payloads.Any(sent => sent.Type == "notification.actionResult") &&
               DateTime.UtcNow < deadline)
        {
            await Task.Delay(20);
        }

        var result = Assert.Single(_transport.Payloads, sent => sent.Type == "notification.actionResult").Payload;
        Assert.Equal("peer-operation", result.GetProperty("operationId").GetString());
        Assert.Equal("Timeout", result.GetProperty("failureReason").GetString());
        var late = await Assert.ThrowsAsync<NotificationSyncFailureException>(() =>
            service.ReportHandledNotificationActionAsync(
                requestId,
                true,
                null,
                null,
                CancellationToken.None));
        Assert.Equal(-32009, late.ErrorCode);
    }

    [Fact]
    public async Task HandleNotificationActionRequestAsync_FailsWhenNoLocalExecutorIsConnected()
    {
        _ipcNotificationService.HasClients = false;
        var service = CreateService();
        await service.HandleNotificationPostedAsync(
            CreateNotification("local-notif", sourceDeviceId: _identityManager.GetDeviceId()),
            CancellationToken.None);

        await service.HandleNotificationActionRequestAsync(
            CreateIncomingActionRequest("peer-operation", "local-notif"),
            CancellationToken.None);

        Assert.DoesNotContain(
            _ipcNotificationService.Events,
            evt => evt.Method == "rift.onNotificationActionRequest");
        var result = Assert.Single(_transport.Payloads, sent => sent.Type == "notification.actionResult").Payload;
        Assert.Equal("CapabilityUnavailable", result.GetProperty("failureReason").GetString());
    }

    [Fact]
    public async Task HandleNotificationActionRequestAsync_RemovesPendingRequestWhenPeerDisconnects()
    {
        var service = CreateService(actionTimeout: TimeSpan.FromSeconds(5));
        await service.HandleNotificationPostedAsync(
            CreateNotification("local-notif", sourceDeviceId: _identityManager.GetDeviceId()),
            CancellationToken.None);
        await service.HandleNotificationActionRequestAsync(
            CreateIncomingActionRequest("peer-operation", "local-notif"),
            CancellationToken.None);
        var notification = Assert.Single(
            _ipcNotificationService.Events,
            evt => evt.Method == "rift.onNotificationActionRequest");
        var requestId = JsonSerializer.SerializeToElement(notification.Payload)
            .GetProperty("requestId")
            .GetString()!;

        _transport.RaiseSessionStateChanged(new SessionStateChangedEventArgs(
            "rift-peer",
            isOnline: false,
            selectedCapabilities: [],
            allowsProtectedTraffic: false));

        var late = await Assert.ThrowsAsync<NotificationSyncFailureException>(() =>
            service.ReportHandledNotificationActionAsync(
                requestId,
                true,
                null,
                null,
                CancellationToken.None));
        Assert.Equal(-32009, late.ErrorCode);
        Assert.DoesNotContain(_transport.Payloads, sent => sent.Type == "notification.actionResult");
    }

    [Fact]
    public async Task HandleNotificationActionRequestAsync_DirectHandlerDeclineFailsWithoutIpcFallback()
    {
        var localActionHandler = new RecordingLocalNotificationActionHandler
        {
            CanPerformResult = false
        };
        var service = CreateService(localActionHandler: localActionHandler);
        await service.HandleNotificationPostedAsync(
            CreateNotification("local-notif", sourceDeviceId: _identityManager.GetDeviceId()),
            CancellationToken.None);

        await service.HandleNotificationActionRequestAsync(
            CreateIncomingActionRequest("peer-operation", "local-notif"),
            CancellationToken.None);

        Assert.Empty(localActionHandler.Performed);
        Assert.DoesNotContain(
            _ipcNotificationService.Events,
            evt => evt.Method == "rift.onNotificationActionRequest");
        var result = Assert.Single(_transport.Payloads, sent => sent.Type == "notification.actionResult").Payload;
        Assert.Equal("CapabilityUnavailable", result.GetProperty("failureReason").GetString());
    }

    [Fact]
    public async Task HandleNotificationActionResultAsync_IgnoresMismatchedCorrelations()
    {
        _presenceService.UpdatePeerPresence("rift-peer", "online", null, ["notification.sync"]);
        _transport.ActivePeers.Add("rift-peer");
        await _service.HandleNotificationPostedAsync(CreateNotification("notif-1"), CancellationToken.None);
        var pending = await _service.PerformNotificationActionAsync(
            "rift-peer",
            "notif-1",
            "dismiss",
            CancellationToken.None);

        await Assert.ThrowsAsync<InvalidOperationException>(() =>
            _service.HandleNotificationActionResultAsync(CreateActionResult(sourceDeviceId: "rift-other"), CancellationToken.None));
        await Assert.ThrowsAsync<InvalidOperationException>(() =>
            _service.HandleNotificationActionResultAsync(CreateActionResult(requestingDeviceId: "rift-someone-else"), CancellationToken.None));
        await Assert.ThrowsAsync<InvalidOperationException>(() =>
            _service.HandleNotificationActionResultAsync(CreateActionResult(action: "open"), CancellationToken.None));

        Assert.Equal("Dispatched", _operationService.GetOperation(pending.OperationId).State);

        await _service.HandleNotificationActionResultAsync(
            CreateActionResult(operationId: pending.OperationId),
            CancellationToken.None);

        Assert.Equal("Done", _operationService.GetOperation(pending.OperationId).State);
    }

    [Fact]
    public async Task HandleLocalNotificationEventAsync_PreservesSourceAdapterActionAdvertisement()
    {
        _presenceService.UpdatePeerPresence("rift-peer", "online", null, ["notification.sync"]);
        _transport.ActivePeers.Add("rift-peer");

        await _service.HandleLocalNotificationEventAsync(
            "posted",
            new NotificationSyncRecord
            {
                NotificationId = "desktop-actionable",
                SourceDeviceId = _identityManager.GetDeviceId(),
                SourcePlatform = "macos",
                PackageName = "dev.rift.desktop",
                AppName = "Rift Desktop",
                PostedAt = "2026-07-16T10:00:00Z",
                IsDismissible = true,
                IsOpenable = true
            },
            null,
            CancellationToken.None);

        var payload = Assert.Single(_transport.Payloads, sent => sent.Type == "notification.posted").Payload;
        Assert.True(payload.GetProperty("isDismissible").GetBoolean());
        Assert.True(payload.GetProperty("isOpenable").GetBoolean());
        var listed = await _service.ListNotificationsAsync(CancellationToken.None);
        var stored = Assert.Single(listed.Notifications);
        Assert.True(stored.IsDismissible);
        Assert.True(stored.IsOpenable);
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

        var actionTask = service.PerformNotificationActionAsync("rift-peer", "notif-race", "open", CancellationToken.None);
        await delayedTransport.WaitForSendStartedAsync();
        var operationId = Assert.Single(
            delayedTransport.Payloads,
            sent => sent.Type == "notification.actionRequest").Payload.GetProperty("operationId").GetString();
        await service.HandleNotificationActionResultAsync(new NotificationActionResultRecord
        {
            OperationId = operationId!,
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
    public async Task NotificationPolicy_DefaultsToAll()
    {
        var result = await _service.ListNotificationsAsync(CancellationToken.None);

        Assert.True(result.Policy.Enabled);
        Assert.Equal(NotificationSyncPolicyModes.All, result.Policy.Mode);
        Assert.Empty(result.Policy.PackageNames);
    }

    [Theory]
    [InlineData(NotificationSyncPolicyModes.All, true, "com.example.other", false)]
    [InlineData(NotificationSyncPolicyModes.Exclude, true, "com.blocked", true)]
    [InlineData(NotificationSyncPolicyModes.Exclude, true, "com.example.other", false)]
    [InlineData(NotificationSyncPolicyModes.Include, true, "com.blocked", false)]
    [InlineData(NotificationSyncPolicyModes.Include, true, "com.example.other", true)]
    [InlineData(NotificationSyncPolicyModes.Include, false, "com.allowed", true)]
    public async Task HandleLocalNotificationEventAsync_AppliesAllPolicyModes(
        string mode,
        bool enabled,
        string packageName,
        bool expectedSuppressed)
    {
        await _service.UpdateNotificationSyncPolicyAsync(
            enabled,
            mode,
            ["com.blocked"],
            CancellationToken.None);

        var result = await _service.HandleLocalNotificationEventAsync(
            "posted",
            new NotificationSyncRecord
            {
                NotificationId = Guid.NewGuid().ToString("N"),
                SourceDeviceId = _identityManager.GetDeviceId(),
                SourcePlatform = "windows",
                PackageName = packageName,
                AppName = "Example App",
                PostedAt = "2026-07-16T10:00:00Z",
                IsDismissible = false,
                IsOpenable = false
            },
            null,
            CancellationToken.None);

        var listed = await _service.ListNotificationsAsync(CancellationToken.None);

        Assert.Equal(expectedSuppressed, result.Suppressed);
        Assert.Equal(expectedSuppressed ? 0 : 1, listed.Notifications.Count);
        Assert.Empty(result.BroadcastTo);
    }

    [Fact]
    public async Task NotificationPolicy_NormalizesPackageNamesDeterministically()
    {
        var result = await _service.UpdateNotificationSyncPolicyAsync(
            true,
            NotificationSyncPolicyModes.Exclude,
            [" com.foo ", "com.bar", "com.foo", ""],
            CancellationToken.None);

        Assert.Equal(["com.bar", "com.foo"], result.PackageNames);
    }

    [Fact]
    public async Task NotificationPolicy_IncludeWithEmptyPackageListSyncsNothing()
    {
        var policy = await _service.UpdateNotificationSyncPolicyAsync(
            true,
            NotificationSyncPolicyModes.Include,
            [],
            CancellationToken.None);

        var result = await _service.HandleLocalNotificationEventAsync(
            "posted",
            new NotificationSyncRecord
            {
                NotificationId = "include-empty",
                SourceDeviceId = _identityManager.GetDeviceId(),
                SourcePlatform = "windows",
                PackageName = "com.example.any",
                AppName = "Example App",
                PostedAt = "2026-07-16T10:00:00Z",
                IsDismissible = false,
                IsOpenable = false
            },
            null,
            CancellationToken.None);

        var listed = await _service.ListNotificationsAsync(CancellationToken.None);

        Assert.Equal(NotificationSyncPolicyModes.Include, policy.Mode);
        Assert.True(result.Suppressed);
        Assert.Empty(result.BroadcastTo);
        Assert.Empty(listed.Notifications);
        var observedApp = Assert.Single(listed.ObservedApps);
        Assert.Equal("com.example.any", observedApp.PackageName);
        Assert.Equal("Example App", observedApp.AppName);
    }

    [Fact]
    public async Task NotificationPolicy_RejectsInvalidMode()
    {
        var exception = await Assert.ThrowsAsync<NotificationSyncFailureException>(() =>
            _service.UpdateNotificationSyncPolicyAsync(
                true,
                "banana",
                [],
                CancellationToken.None));

        Assert.Equal(-32602, exception.ErrorCode);
    }

    [Fact]
    public async Task HandleLocalNotificationEventAsync_RemovalIgnoresCurrentPolicy()
    {
        _presenceService.UpdatePeerPresence("rift-peer", "online", null, ["notification.sync"]);
        _transport.ActivePeers.Add("rift-peer");
        var notification = new NotificationSyncRecord
        {
            NotificationId = "notif-policy-removal",
            SourceDeviceId = _identityManager.GetDeviceId(),
            SourcePlatform = "windows",
            PackageName = "com.example.chat",
            AppName = "Example Chat",
            PostedAt = "2026-07-16T10:00:00Z",
            IsDismissible = false,
            IsOpenable = false
        };

        await _service.HandleLocalNotificationEventAsync(
            "posted",
            notification,
            null,
            CancellationToken.None);
        await _service.UpdateNotificationSyncPolicyAsync(
            true,
            NotificationSyncPolicyModes.Exclude,
            ["com.example.chat"],
            CancellationToken.None);

        var result = await _service.HandleLocalNotificationEventAsync(
            "removed",
            notification,
            "2026-07-16T10:01:00Z",
            CancellationToken.None);

        Assert.False(result.Suppressed);
        Assert.Contains("rift-peer", result.BroadcastTo);
        Assert.Contains(
            _transport.SentMessages,
            sent => sent.PeerDeviceId == "rift-peer" && sent.Type == "notification.removed");
    }

    [Fact]
    public async Task HandleLocalNotificationEventAsync_DoesNotStoreOrBroadcastSuppressedNotifications()
    {
        await _service.UpdateNotificationSyncPolicyAsync(
            enabled: true,
            mode: NotificationSyncPolicyModes.Exclude,
            packageNames: ["dev.rift.desktop"],
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
                Mode = NotificationSyncPolicyModes.Exclude,
                PackageNames = ["org.example.Secret"]
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
            mode: NotificationSyncPolicyModes.Exclude,
            packageNames: [" org.example.Chat ", "org.example.Chat"],
            cancellationToken: CancellationToken.None);

        Assert.False(initial.Policy.Enabled);
        Assert.Equal(NotificationSyncPolicyModes.Exclude, initial.Policy.Mode);
        Assert.Equal(["org.example.Secret"], initial.Policy.PackageNames);
        Assert.NotNull(store.StoredPolicy);
        Assert.True(store.StoredPolicy.Enabled);
        Assert.Equal(NotificationSyncPolicyModes.Exclude, store.StoredPolicy.Mode);
        Assert.Equal(["org.example.Chat"], store.StoredPolicy.PackageNames);
    }

    [Fact]
    public async Task NotificationPolicy_UpdateRollsBackAndPropagatesWhenPersistenceFails()
    {
        var store = new RecordingNotificationSyncPolicyStore
        {
            StoredPolicy = new NotificationSyncPolicy
            {
                Enabled = true,
                Mode = NotificationSyncPolicyModes.Exclude,
                PackageNames = ["org.example.Secret"]
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
                mode: NotificationSyncPolicyModes.Exclude,
                packageNames: ["org.example.Chat"],
                cancellationToken: CancellationToken.None));
        var current = await service.ListNotificationsAsync(CancellationToken.None);

        Assert.Equal("database is read-only", exception.Message);
        Assert.True(current.Policy.Enabled);
        Assert.Equal(NotificationSyncPolicyModes.Exclude, current.Policy.Mode);
        Assert.Equal(["org.example.Secret"], current.Policy.PackageNames);
    }

    public void Dispose()
    {
        SqliteConnection.ClearAllPools();
        if (File.Exists(_databasePath))
        {
            File.Delete(_databasePath);
        }
    }

    private NotificationSyncService CreateService(
        TimeSpan? actionTimeout = null,
        ILocalNotificationActionHandler? localActionHandler = null) =>
        new(
            _transport,
            _presenceService,
            _identityManager,
            _operationService,
            _securityEventLog,
            _ipcNotificationService,
            NullLogger<NotificationSyncService>.Instance,
            actionTimeout: actionTimeout,
            localActionHandler: localActionHandler);

    private NotificationActionRequestRecord CreateIncomingActionRequest(
        string operationId,
        string notificationId,
        string action = "dismiss",
        string? requestedAt = null) => new()
        {
            OperationId = operationId,
            NotificationId = notificationId,
            SourceDeviceId = _identityManager.GetDeviceId(),
            RequestingDeviceId = "rift-peer",
            Action = action,
            RequestedAt = requestedAt
        };

    private sealed class RecordingLocalNotificationActionHandler : ILocalNotificationActionHandler
    {
        public bool CanPerformResult { get; set; } = true;
        public LocalNotificationActionResult Result { get; set; } = new() { Success = true };
        public List<(NotificationSyncRecord Notification, string Action)> Performed { get; } = [];

        public bool CanPerform(NotificationSyncRecord notification, string action) => CanPerformResult;

        public Task<LocalNotificationActionResult> PerformAsync(
            NotificationSyncRecord notification,
            string action,
            CancellationToken cancellationToken)
        {
            Performed.Add((notification, action));
            return Task.FromResult(Result);
        }
    }

    private static NotificationSyncRecord CreateNotification(
        string notificationId,
        string? title = "Title",
        string? bodyPreview = "Body",
        bool isDismissible = true,
        bool isOpenable = false,
        string sourceDeviceId = "rift-peer",
        IReadOnlyDictionary<string, object?>? icon = null)
    {
        return new NotificationSyncRecord
        {
            NotificationId = notificationId,
            SourceDeviceId = sourceDeviceId,
            PackageName = "com.example.chat",
            AppName = "Example Chat",
            Title = title,
            BodyPreview = bodyPreview,
            PostedAt = "2026-07-14T10:00:00Z",
            IsDismissible = isDismissible,
            IsOpenable = isOpenable,
            Icon = icon
        };
    }

    private static Dictionary<string, object?> CreateIcon()
    {
        var bytes = Convert.FromBase64String(
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==");
        return new Dictionary<string, object?>
        {
            ["mediaType"] = "image/png",
            ["dataBase64"] = Convert.ToBase64String(bytes),
            ["byteSize"] = bytes.Length,
            ["sha256"] = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(bytes)).ToLowerInvariant()
        };
    }

    private NotificationActionResultRecord CreateActionResult(
        string? operationId = null,
        string notificationId = "notif-1",
        string sourceDeviceId = "rift-peer",
        string? requestingDeviceId = null,
        string action = "dismiss",
        bool success = true,
        string? failureReason = null,
        string? message = null)
    {
        return new NotificationActionResultRecord
        {
            OperationId = operationId ?? "operation-1",
            NotificationId = notificationId,
            SourceDeviceId = sourceDeviceId,
            RequestingDeviceId = requestingDeviceId ?? _identityManager.GetDeviceId(),
            Action = action,
            Success = success,
            FailureReason = failureReason,
            Message = message
        };
    }

    private sealed class RecordingNotificationSyncPolicyStore : INotificationSyncPolicyStore
    {
        public NotificationSyncPolicy StoredPolicy { get; set; } = new()
        {
            Enabled = true,
            Mode = NotificationSyncPolicyModes.All,
            PackageNames = []
        };

        public Exception? SaveException { get; init; }

        public NotificationSyncPolicy Load() => new()
        {
            Enabled = StoredPolicy.Enabled,
            Mode = StoredPolicy.Mode,
            PackageNames = StoredPolicy.PackageNames.ToArray()
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
                Mode = policy.Mode,
                PackageNames = policy.PackageNames.ToArray()
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

        public event EventHandler<SessionStateChangedEventArgs>? SessionStateChanged;

        public void RaiseSessionStateChanged(SessionStateChangedEventArgs args) =>
            SessionStateChanged?.Invoke(this, args);

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

    private sealed class RecordingIpcNotificationService :
        IIpcNotificationService,
        IIpcNotificationActionExecutorService
    {
        public bool HasClients { get; set; } = true;
        public bool HasExecutor => HasClients;
        public List<(string Method, object Payload)> Events { get; } = [];

        public IDisposable RegisterClient(JsonRpc jsonRpc) => NullDisposable.Instance;

        public bool TryAcquire(JsonRpc jsonRpc) => HasClients;

        public bool Release(JsonRpc jsonRpc) => true;

        public Task NotifyAsync(string method, object parameters, CancellationToken cancellationToken = default)
        {
            Events.Add((method, parameters));
            return Task.CompletedTask;
        }

        public Task<bool> NotifyExecutorAsync(
            string method,
            object parameters,
            CancellationToken cancellationToken = default)
        {
            if (!HasExecutor)
            {
                return Task.FromResult(false);
            }

            Events.Add((method, parameters));
            return Task.FromResult(true);
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
