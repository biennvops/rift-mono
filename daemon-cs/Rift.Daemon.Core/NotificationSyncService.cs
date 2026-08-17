using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;
using Rift.Daemon.Core.Interfaces;

namespace Rift.Daemon.Core;

public sealed class NotificationSyncService : INotificationSyncService
{
    private const string RequiredCapability = "notification.sync";
    private static readonly StringComparer Comparer = StringComparer.Ordinal;
    private static readonly TimeSpan DefaultActionTimeout = TimeSpan.FromSeconds(30);
    private static readonly Regex Rfc3339UtcTimestamp = new(
        @"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|\+00:00)$",
        RegexOptions.CultureInvariant);
    private static readonly HashSet<string> FailureReasons = new(Comparer)
    {
        "PeerUnreachable",
        "PeerRejected",
        "OfferExpired",
        "CapabilityUnavailable",
        "ConnectionLost",
        "Timeout",
        "PolicyDenied",
        "AuthenticationFailed",
        "Unauthorized",
        "HashMismatch",
        "MalformedMessage",
        "VersionMismatch",
        "ProtocolError",
        "PayloadTooLarge",
        "InvalidTransition"
    };
    private readonly Lock _gate = new();
    private readonly Lock _windowsNotificationLifecycleGate = new();
    private readonly ITransport _transport;
    private readonly IPresenceService _presenceService;
    private readonly IIdentityManager _identityManager;
    private readonly IOperationService _operationService;
    private readonly ISecurityEventLog _securityEventLog;
    private readonly IIpcNotificationService? _ipcNotificationService;
    private readonly IIpcNotificationActionExecutorService? _notificationActionExecutorService;
    private readonly ILocalNotificationActionHandler? _localActionHandler;
    private readonly INotificationSyncPolicyStore? _policyStore;
    private readonly ILogger<NotificationSyncService> _logger;
    private readonly TimeSpan _actionTimeout;
    private readonly Dictionary<string, NotificationSyncRecord> _notifications = new(StringComparer.Ordinal);
    private readonly Dictionary<string, NotificationSyncObservedApp> _observedAppsByPackage = new(StringComparer.Ordinal);
    private readonly Dictionary<string, PendingNotificationAction> _pendingActionsByOperationId = new(StringComparer.Ordinal);
    private readonly Dictionary<string, string> _pendingActionKeys = new(StringComparer.Ordinal);
    private readonly Dictionary<string, PendingIncomingNotificationAction> _pendingIncomingActionsByRequestId = new(StringComparer.Ordinal);
    private readonly Dictionary<string, Timer> _pendingIncomingActionTimers = new(StringComparer.Ordinal);
    private Task _windowsNotificationLifecycleQueue = Task.CompletedTask;
    private NotificationSyncPolicy _policy;

    public NotificationSyncService(
        ITransport transport,
        IPresenceService presenceService,
        IIdentityManager identityManager,
        IOperationService operationService,
        ISecurityEventLog securityEventLog,
        IIpcNotificationService? ipcNotificationService = null,
        ILogger<NotificationSyncService>? logger = null,
        INotificationSyncPolicyStore? policyStore = null,
        TimeSpan? actionTimeout = null,
        ILocalNotificationActionHandler? localActionHandler = null)
    {
        _transport = transport;
        _presenceService = presenceService;
        _identityManager = identityManager;
        _operationService = operationService;
        _securityEventLog = securityEventLog;
        _ipcNotificationService = ipcNotificationService;
        _notificationActionExecutorService = ipcNotificationService as IIpcNotificationActionExecutorService;
        if (_notificationActionExecutorService is not null)
        {
            _notificationActionExecutorService.ExecutorUnavailable += OnNotificationActionExecutorUnavailable;
        }
        _localActionHandler = localActionHandler;
        _policyStore = policyStore;
        _logger = logger ?? NullLogger<NotificationSyncService>.Instance;
        _actionTimeout = actionTimeout ?? DefaultActionTimeout;
        _transport.SessionStateChanged += OnSessionStateChanged;
        _policy = policyStore?.Load() ?? new NotificationSyncPolicy
        {
            Enabled = true,
            Mode = NotificationSyncPolicyModes.All,
            PackageNames = []
        };
    }

    public Task<ListNotificationsResult> ListNotificationsAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();

        lock (_gate)
        {
            return Task.FromResult(new ListNotificationsResult
            {
                Notifications = _notifications.Values
                    .Where(notification => !notification.IsRemoved)
                    .Select(notification => CloneRecord(notification))
                    .ToArray(),
                ObservedApps = _observedAppsByPackage.Values
                    .OrderBy(app => app.AppName, StringComparer.Ordinal)
                    .ThenBy(app => app.PackageName, StringComparer.Ordinal)
                    .Select(CloneObservedApp)
                    .ToArray(),
                Policy = ClonePolicy(_policy)
            });
        }
    }

    public Task<NotifyLocalNotificationEventResult> HandleLocalNotificationEventAsync(
        string eventType,
        NotificationSyncRecord notification,
        string? removedAt,
        CancellationToken cancellationToken)
    {
        if (string.Equals(notification.SourcePlatform, "windows", StringComparison.OrdinalIgnoreCase))
        {
            return EnqueueWindowsNotificationLifecycleAsync(
                () => HandleLocalNotificationEventCoreAsync(
                    eventType,
                    notification,
                    removedAt,
                    cancellationToken));
        }

        return HandleLocalNotificationEventCoreAsync(
            eventType,
            notification,
            removedAt,
            cancellationToken);
    }

    private async Task<NotifyLocalNotificationEventResult> HandleLocalNotificationEventCoreAsync(
        string eventType,
        NotificationSyncRecord notification,
        string? removedAt,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();

        if (string.IsNullOrWhiteSpace(eventType))
        {
            throw new NotificationSyncFailureException("A notification eventType is required.", -32602);
        }

        var normalizedEventType = eventType.Trim();
        if (string.Equals(normalizedEventType, "removed", StringComparison.Ordinal))
        {
            var removal = new NotificationRemovedRecord
            {
                NotificationId = notification.NotificationId,
                SourceDeviceId = notification.SourceDeviceId,
                RemovedAt = removedAt
            };
            await HandleNotificationRemovedAsync(removal, cancellationToken).ConfigureAwait(false);
            var removedBroadcast = await BroadcastNotificationAsync(
                "notification.removed",
                new
                {
                    notificationId = removal.NotificationId,
                    sourceDeviceId = removal.SourceDeviceId,
                    removedAt = removal.RemovedAt
                },
                cancellationToken).ConfigureAwait(false);
            return new NotifyLocalNotificationEventResult
            {
                NotificationId = notification.NotificationId,
                BroadcastTo = removedBroadcast,
                Suppressed = false
            };
        }

        var normalizedNotification = NormalizeLocalNotification(notification);
        ValidateNotification(normalizedNotification);
        ObserveLocalNotificationApp(normalizedNotification);

        var shouldSync = ShouldSyncNotification(normalizedNotification.PackageName);
        if (!shouldSync &&
            (string.Equals(normalizedEventType, "posted", StringComparison.Ordinal) ||
             string.Equals(normalizedEventType, "updated", StringComparison.Ordinal)))
        {
            return new NotifyLocalNotificationEventResult
            {
                NotificationId = normalizedNotification.NotificationId,
                BroadcastTo = [],
                Suppressed = true
            };
        }

        if (string.Equals(normalizedEventType, "posted", StringComparison.Ordinal))
        {
            await HandleNotificationPostedAsync(normalizedNotification, cancellationToken).ConfigureAwait(false);
        }
        else if (string.Equals(normalizedEventType, "updated", StringComparison.Ordinal))
        {
            await HandleNotificationUpdatedAsync(normalizedNotification, cancellationToken).ConfigureAwait(false);
        }
        else
        {
            throw new NotificationSyncFailureException("Notification eventType must be posted, updated, or removed.", -32602);
        }

        var broadcastTo = await BroadcastNotificationAsync(
            string.Equals(normalizedEventType, "posted", StringComparison.Ordinal)
                ? "notification.posted"
                : "notification.updated",
            CreateNotificationPayload(normalizedNotification),
            cancellationToken).ConfigureAwait(false);

        return new NotifyLocalNotificationEventResult
        {
            NotificationId = normalizedNotification.NotificationId,
            BroadcastTo = broadcastTo,
            Suppressed = !shouldSync
        };
    }

    public async Task<PerformNotificationActionResult> PerformNotificationActionAsync(
        string sourceDeviceId,
        string notificationId,
        string action,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();

        if (string.IsNullOrWhiteSpace(sourceDeviceId))
        {
            throw new NotificationSyncFailureException("A notification sourceDeviceId is required.", -32009);
        }

        if (string.IsNullOrWhiteSpace(notificationId))
        {
            throw new NotificationSyncFailureException("A notification ID is required.", -32009);
        }

        var normalizedAction = NormalizeAction(action);
        NotificationSyncRecord notification;
        lock (_gate)
        {
            if (!_notifications.TryGetValue(GetNotificationKey(sourceDeviceId, notificationId), out var stored) ||
                stored.IsRemoved)
            {
                throw new NotificationSyncFailureException(
                    $"Mirrored notification '{notificationId}' from '{sourceDeviceId}' was not found.",
                    -32009);
            }

            notification = stored;
        }

        EnsureActionAllowed(notification, normalizedAction);
        EnsurePeerCanUseNotificationSync(notification.SourceDeviceId);

        var operationId = Guid.NewGuid().ToString("D");
        var operationType = normalizedAction == "open" ? "notification.open" : "notification.dismiss";
        var actionKey = GetPendingActionKey(notification.SourceDeviceId, notification.NotificationId, normalizedAction);
        lock (_gate)
        {
            if (_pendingActionKeys.ContainsKey(actionKey))
            {
                throw new NotificationSyncFailureException("A matching notification action is pending.", -32010);
            }

            _pendingActionKeys[actionKey] = operationId;
        }

        try
        {
            _operationService.CreateOperation(operationId, operationType, _identityManager.GetDeviceId(), notification.SourceDeviceId);
            _operationService.TransitionOperation(operationId, OperationState.Pending, details: CreateOperationDetails(notification, normalizedAction));
            var pending = new PendingNotificationAction(
                operationId,
                notification.NotificationId,
                notification.SourceDeviceId,
                normalizedAction);

            lock (_gate)
            {
                _pendingActionsByOperationId[operationId] = pending;
            }
            _operationService.TransitionOperation(operationId, OperationState.Dispatched);
            pending.ExpiryTimer = new Timer(_ => ExpirePendingAction(operationId), null, _actionTimeout, Timeout.InfiniteTimeSpan);
        }
        catch
        {
            RemovePendingAction(operationId, notification.SourceDeviceId, notification.NotificationId, normalizedAction)?.ExpiryTimer?.Dispose();
            throw;
        }

        var envelope = CreateEnvelope(
            "notification.actionRequest",
            new
            {
                operationId,
                notificationId = notification.NotificationId,
                sourceDeviceId = notification.SourceDeviceId,
                requestingDeviceId = _identityManager.GetDeviceId(),
                action = normalizedAction,
                requestedAt = DateTimeOffset.UtcNow.ToString("O")
            });

        try
        {
            var bytes = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(envelope));
            await _transport.SendAsync(notification.SourceDeviceId, bytes, cancellationToken).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            var pending = RemovePendingAction(operationId, notification.SourceDeviceId, notification.NotificationId, normalizedAction);
            pending?.ExpiryTimer?.Dispose();
            if (pending is not null)
            {
                _operationService.TransitionOperation(operationId, OperationState.Failed, "PeerUnreachable");
            }
            throw new NotificationSyncFailureException($"Failed to send notification action request: {ex.Message}", -32003);
        }

        return new PerformNotificationActionResult
        {
            OperationId = operationId,
            SourceDeviceId = notification.SourceDeviceId,
            NotificationId = notification.NotificationId,
            Action = normalizedAction,
            State = "Pending"
        };
    }

    public Task<NotificationSyncPolicy> UpdateNotificationSyncPolicyAsync(
        bool enabled,
        string mode,
        IReadOnlyList<string> packageNames,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();

        var normalizedMode = NotificationSyncPolicyModes.Validate(mode);
        var normalizedPackageNames = NotificationSyncPolicyModes.NormalizePackageNames(packageNames);

        lock (_gate)
        {
            var previous = ClonePolicy(_policy);
            var updated = new NotificationSyncPolicy
            {
                Enabled = enabled,
                Mode = normalizedMode,
                PackageNames = normalizedPackageNames
            };

            _policy = updated;
            try
            {
                _policyStore?.Save(updated);
            }
            catch
            {
                _policy = previous;
                throw;
            }

            return Task.FromResult(ClonePolicy(_policy));
        }
    }

    public async Task HandleNotificationPostedAsync(NotificationSyncRecord notification, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var normalizedNotification = NormalizeNotificationRecord(notification);
        ValidateNotification(normalizedNotification);

        lock (_gate)
        {
            _notifications[GetNotificationKey(
                normalizedNotification.SourceDeviceId,
                normalizedNotification.NotificationId)] = CloneRecord(normalizedNotification);
        }

        await NotifyIpcAsync("rift.onNotificationPosted", normalizedNotification).ConfigureAwait(false);
        await LogEventAsync(SecurityEventTypes.NotificationSynced, normalizedNotification.SourceDeviceId, SecurityEventOutcome.Success, null, new Dictionary<string, object?>
        {
            ["notificationId"] = normalizedNotification.NotificationId,
            ["packageName"] = normalizedNotification.PackageName
        }).ConfigureAwait(false);
    }

    public async Task HandleNotificationUpdatedAsync(NotificationSyncRecord notification, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var normalizedNotification = NormalizeNotificationRecord(notification);
        ValidateNotification(normalizedNotification);

        lock (_gate)
        {
            _notifications[GetNotificationKey(
                normalizedNotification.SourceDeviceId,
                normalizedNotification.NotificationId)] = CloneRecord(normalizedNotification);
        }

        await NotifyIpcAsync("rift.onNotificationUpdated", normalizedNotification).ConfigureAwait(false);
        await LogEventAsync(SecurityEventTypes.NotificationSynced, normalizedNotification.SourceDeviceId, SecurityEventOutcome.Success, null, new Dictionary<string, object?>
        {
            ["notificationId"] = normalizedNotification.NotificationId,
            ["packageName"] = normalizedNotification.PackageName,
            ["updated"] = true
        }).ConfigureAwait(false);
    }

    public async Task HandleNotificationRemovedAsync(NotificationRemovedRecord notification, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();

        if (string.IsNullOrWhiteSpace(notification.NotificationId) || string.IsNullOrWhiteSpace(notification.SourceDeviceId))
        {
            throw new InvalidOperationException("Notification removal requires both sourceDeviceId and notificationId.");
        }

        var removedAt = notification.RemovedAt ?? DateTimeOffset.UtcNow.ToString("O");
        lock (_gate)
        {
            _notifications.Remove(GetNotificationKey(
                notification.SourceDeviceId,
                notification.NotificationId));
        }

        await NotifyIpcAsync("rift.onNotificationRemoved", new
        {
            notificationId = notification.NotificationId,
            sourceDeviceId = notification.SourceDeviceId,
            removedAt
        }).ConfigureAwait(false);
        await LogEventAsync(SecurityEventTypes.NotificationRemoved, notification.SourceDeviceId, SecurityEventOutcome.Success, null, new Dictionary<string, object?>
        {
            ["notificationId"] = notification.NotificationId
        }).ConfigureAwait(false);
    }

    public async Task HandleNotificationActionResultAsync(NotificationActionResultRecord result, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();

        if (!string.Equals(result.RequestingDeviceId, _identityManager.GetDeviceId(), StringComparison.Ordinal))
        {
            throw new InvalidOperationException("notification.actionResult requestingDeviceId did not match the local device identity.");
        }

        if (string.IsNullOrWhiteSpace(result.OperationId))
        {
            throw new InvalidOperationException("notification.actionResult operationId is required.");
        }

        var action = NormalizeAction(result.Action);
        PendingNotificationAction pending;
        lock (_gate)
        {
            if (!_pendingActionsByOperationId.TryGetValue(result.OperationId, out pending!))
            {
                throw new InvalidOperationException($"No pending notification action exists for operation '{result.OperationId}'.");
            }

            if (!string.Equals(pending.SourceDeviceId, result.SourceDeviceId, StringComparison.Ordinal) ||
                !string.Equals(pending.NotificationId, result.NotificationId, StringComparison.Ordinal) ||
                !string.Equals(pending.Action, action, StringComparison.Ordinal))
            {
                throw new InvalidOperationException($"Notification action result did not match pending operation '{result.OperationId}'.");
            }

            var pendingKey = GetPendingActionKey(pending.SourceDeviceId, pending.NotificationId, pending.Action);
            _pendingActionsByOperationId.Remove(result.OperationId);
            _pendingActionKeys.Remove(pendingKey);
        }
        pending.ExpiryTimer?.Dispose();

        TryTransitionActive(pending.OperationId);
        if (result.Success)
        {
            _operationService.TransitionOperation(pending.OperationId, OperationState.Done);
        }
        else
        {
            _operationService.TransitionOperation(
                pending.OperationId,
                OperationState.Failed,
                string.IsNullOrWhiteSpace(result.FailureReason) ? "Rejected" : result.FailureReason,
                details: string.IsNullOrWhiteSpace(result.Message)
                    ? null
                    : new Dictionary<string, object?> { ["message"] = result.Message });
        }

        await NotifyIpcAsync("rift.onNotificationActionResult", new
        {
            notificationId = result.NotificationId,
            sourceDeviceId = result.SourceDeviceId,
            action,
            operationId = pending.OperationId,
            state = result.Success ? "Done" : "Failed",
            success = result.Success,
            failureReason = result.FailureReason,
            message = result.Message
        }).ConfigureAwait(false);
        await LogEventAsync(SecurityEventTypes.NotificationActioned, result.SourceDeviceId, result.Success ? SecurityEventOutcome.Success : SecurityEventOutcome.Failure, result.FailureReason, new Dictionary<string, object?>
        {
            ["notificationId"] = result.NotificationId,
            ["action"] = action,
            ["operationId"] = pending.OperationId,
            ["message"] = result.Message
        }).ConfigureAwait(false);
    }

    public async Task HandleNotificationActionRequestAsync(
        NotificationActionRequestRecord request,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (string.IsNullOrWhiteSpace(request.OperationId) ||
            string.IsNullOrWhiteSpace(request.NotificationId) ||
            string.IsNullOrWhiteSpace(request.SourceDeviceId) ||
            string.IsNullOrWhiteSpace(request.RequestingDeviceId))
        {
            throw new InvalidOperationException(
                "notification.actionRequest requires operationId, notificationId, sourceDeviceId, and requestingDeviceId.");
        }
        if (!string.Equals(request.SourceDeviceId, _identityManager.GetDeviceId(), StringComparison.Ordinal))
        {
            throw new UnauthorizedAccessException(
                "notification.actionRequest sourceDeviceId did not match the local device identity.");
        }

        ValidateOptionalAuditTimestamp(request.RequestedAt, "requestedAt");
        if (!TryNormalizeAction(request.Action, out var action))
        {
            await SendIncomingActionResultAsync(
                CreatePendingIncomingAction(request, request.Action),
                success: false,
                failureReason: "ProtocolError",
                message: "Unknown notification action.",
                cancellationToken).ConfigureAwait(false);
            return;
        }

        NotificationSyncRecord? notification;
        lock (_gate)
        {
            _notifications.TryGetValue(
                GetNotificationKey(request.SourceDeviceId, request.NotificationId),
                out notification);
        }

        var pending = CreatePendingIncomingAction(request, action);
        if (notification is null || notification.IsRemoved)
        {
            await SendIncomingActionResultAsync(
                pending,
                success: false,
                failureReason: "CapabilityUnavailable",
                message: "The local notification was not found.",
                cancellationToken).ConfigureAwait(false);
            return;
        }
        if (!IsActionAllowed(notification, action))
        {
            await SendIncomingActionResultAsync(
                pending,
                success: false,
                failureReason: "PolicyDenied",
                message: $"The local notification does not allow action '{action}'.",
                cancellationToken).ConfigureAwait(false);
            return;
        }

        if (_localActionHandler is not null)
        {
            if (!_localActionHandler.CanPerform(notification, action))
            {
                await SendIncomingActionResultAsync(
                    pending,
                    success: false,
                    failureReason: "CapabilityUnavailable",
                    message: "No daemon-resident notification handler can perform the request.",
                    cancellationToken).ConfigureAwait(false);
                return;
            }

            LocalNotificationActionResult result;
            try
            {
                result = await _localActionHandler.PerformAsync(notification, action, cancellationToken).ConfigureAwait(false);
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                _logger.LogWarning(
                    ex,
                    "Local notification action handler failed for {Action} on {NotificationId}.",
                    action,
                    request.NotificationId);
                result = new LocalNotificationActionResult
                {
                    Success = false,
                    FailureReason = "CapabilityUnavailable",
                    Message = ex.Message
                };
            }

            await SendIncomingActionResultAsync(
                pending,
                result.Success,
                NormalizeFailureReason(result.Success, result.FailureReason, invalidErrorCode: null),
                LimitMessage(result.Message),
                cancellationToken).ConfigureAwait(false);
            return;
        }

        if (_notificationActionExecutorService is null ||
            !_notificationActionExecutorService.HasExecutor)
        {
            await SendIncomingActionResultAsync(
                pending,
                success: false,
                failureReason: "CapabilityUnavailable",
                message: "No local notification action client is connected.",
                cancellationToken).ConfigureAwait(false);
            return;
        }

        lock (_gate)
        {
            _pendingIncomingActionsByRequestId[pending.RequestId] = pending;
            _pendingIncomingActionTimers[pending.RequestId] = new Timer(
                _ => _ = ExpireIncomingActionAsync(pending.RequestId),
                null,
                _actionTimeout,
                Timeout.InfiniteTimeSpan);
        }

        var delivered = await _notificationActionExecutorService.NotifyExecutorAsync(
            "rift.onNotificationActionRequest",
            new
            {
                requestId = pending.RequestId,
                operationId = pending.OperationId,
                notificationId = pending.NotificationId,
                sourceDeviceId = pending.SourceDeviceId,
                requestingDeviceId = pending.RequestingDeviceId,
                action = pending.Action,
                requestedAt = request.RequestedAt
            },
            cancellationToken).ConfigureAwait(false);
        if (delivered)
        {
            return;
        }

        var removed = false;
        lock (_gate)
        {
            removed = _pendingIncomingActionsByRequestId.Remove(pending.RequestId);
            if (_pendingIncomingActionTimers.Remove(pending.RequestId, out var timer))
            {
                timer.Dispose();
            }
        }

        if (removed)
        {
            await SendIncomingActionResultAsync(
                pending,
                success: false,
                failureReason: "CapabilityUnavailable",
                message: "No local notification action client is connected.",
                cancellationToken).ConfigureAwait(false);
        }
    }

    public async Task<ReportHandledNotificationActionResult> ReportHandledNotificationActionAsync(
        string requestId,
        bool success,
        string? failureReason,
        string? message,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (string.IsNullOrWhiteSpace(requestId))
        {
            throw new NotificationSyncFailureException("A notification action request ID is required.", -32009);
        }

        failureReason = NormalizeFailureReason(success, failureReason, invalidErrorCode: -32602);
        PendingIncomingNotificationAction pending;
        lock (_gate)
        {
            if (!_pendingIncomingActionsByRequestId.Remove(requestId, out pending!))
            {
                throw new NotificationSyncFailureException(
                    $"Notification action request '{requestId}' was not found.",
                    -32009);
            }
            if (_pendingIncomingActionTimers.Remove(requestId, out var timer))
            {
                timer.Dispose();
            }
        }

        try
        {
            await SendIncomingActionResultAsync(
                pending,
                success,
                failureReason,
                LimitMessage(message),
                cancellationToken).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            throw new NotificationSyncFailureException(
                $"Failed to send notification action result: {ex.Message}",
                -32003);
        }

        await LogEventAsync(
            SecurityEventTypes.NotificationActioned,
            pending.RequestingDeviceId,
            success ? SecurityEventOutcome.Success : SecurityEventOutcome.Failure,
            failureReason,
            new Dictionary<string, object?>
            {
                ["notificationId"] = pending.NotificationId,
                ["action"] = pending.Action,
                ["operationId"] = pending.OperationId,
                ["requestId"] = requestId,
                ["direction"] = "incoming"
            }).ConfigureAwait(false);

        return new ReportHandledNotificationActionResult
        {
            RequestId = requestId,
            NotificationId = pending.NotificationId,
            Action = pending.Action,
            Success = success
        };
    }

    private static PendingIncomingNotificationAction CreatePendingIncomingAction(
        NotificationActionRequestRecord request,
        string action) => new()
        {
            RequestId = Guid.NewGuid().ToString("D"),
            OperationId = request.OperationId,
            NotificationId = request.NotificationId,
            SourceDeviceId = request.SourceDeviceId,
            RequestingDeviceId = request.RequestingDeviceId,
            Action = action
        };

    private static bool IsActionAllowed(NotificationSyncRecord notification, string action) => action switch
    {
        "open" => notification.IsOpenable,
        "dismiss" => notification.IsDismissible,
        _ => false
    };

    private void EnsureActionAllowed(NotificationSyncRecord notification, string action)
    {
        if (!IsActionAllowed(notification, action))
        {
            throw new NotificationSyncFailureException(
                $"Mirrored notification '{notification.NotificationId}' does not allow action '{action}'.",
                -32010);
        }
    }

    private Task<T> EnqueueWindowsNotificationLifecycleAsync<T>(Func<Task<T>> operation)
    {
        Task predecessor;
        var completion = new TaskCompletionSource<T>(TaskCreationOptions.RunContinuationsAsynchronously);
        lock (_windowsNotificationLifecycleGate)
        {
            predecessor = _windowsNotificationLifecycleQueue;
            _windowsNotificationLifecycleQueue = completion.Task;
        }

        _ = CompleteWindowsNotificationLifecycleAsync(predecessor, operation, completion);
        return completion.Task;
    }

    private Task EnqueueWindowsNotificationLifecycleAsync(Func<Task> operation) =>
        EnqueueWindowsNotificationLifecycleAsync<object?>(async () =>
        {
            await operation().ConfigureAwait(false);
            return null;
        });

    private static async Task CompleteWindowsNotificationLifecycleAsync<T>(
        Task predecessor,
        Func<Task<T>> operation,
        TaskCompletionSource<T> completion)
    {
        try
        {
            await predecessor.ConfigureAwait(false);
        }
        catch
        {
            // A failed event must not poison later Windows lifecycle transitions.
        }

        try
        {
            completion.TrySetResult(await operation().ConfigureAwait(false));
        }
        catch (OperationCanceledException ex)
        {
            completion.TrySetCanceled(ex.CancellationToken);
        }
        catch (Exception ex)
        {
            completion.TrySetException(ex);
        }
    }

    private void OnNotificationActionExecutorUnavailable(object? sender, EventArgs args)
    {
        _ = EnqueueWindowsNotificationLifecycleAsync(InvalidateNotificationActionCapabilitiesAsync);
    }

    private async Task InvalidateNotificationActionCapabilitiesAsync()
    {
        NotificationSyncRecord[] downgraded;
        var localDeviceId = _identityManager.GetDeviceId();
        lock (_gate)
        {
            var keys = _notifications
                .Where(entry =>
                    !entry.Value.IsRemoved &&
                    string.Equals(entry.Value.SourceDeviceId, localDeviceId, StringComparison.Ordinal) &&
                    string.Equals(entry.Value.SourcePlatform, "windows", StringComparison.OrdinalIgnoreCase) &&
                    (entry.Value.IsDismissible || entry.Value.IsOpenable))
                .Select(entry => entry.Key)
                .ToArray();
            downgraded = new NotificationSyncRecord[keys.Length];
            for (var index = 0; index < keys.Length; index++)
            {
                var updated = CloneRecord(
                    _notifications[keys[index]],
                    isDismissible: false,
                    isOpenable: false);
                _notifications[keys[index]] = updated;
                downgraded[index] = CloneRecord(updated);
            }
        }

        foreach (var notification in downgraded)
        {
            await PublishExecutorCapabilityDowngradeAsync(notification).ConfigureAwait(false);
        }
    }

    private async Task PublishExecutorCapabilityDowngradeAsync(NotificationSyncRecord notification)
    {
        try
        {
            await NotifyIpcAsync("rift.onNotificationUpdated", notification).ConfigureAwait(false);
            await BroadcastNotificationAsync(
                "notification.updated",
                CreateNotificationPayload(notification),
                CancellationToken.None).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            _logger.LogWarning(
                ex,
                "Failed to publish notification action capability loss for {NotificationId}.",
                notification.NotificationId);
        }
    }

    private void OnSessionStateChanged(object? sender, SessionStateChangedEventArgs args)
    {
        if (args.IsOnline)
        {
            return;
        }

        Timer[] timers;
        lock (_gate)
        {
            var requestIds = _pendingIncomingActionsByRequestId
                .Where(entry => string.Equals(
                    entry.Value.RequestingDeviceId,
                    args.PeerDeviceId,
                    StringComparison.Ordinal))
                .Select(entry => entry.Key)
                .ToArray();
            timers = requestIds
                .Select(requestId => _pendingIncomingActionTimers.Remove(requestId, out var timer) ? timer : null)
                .Where(timer => timer is not null)
                .Cast<Timer>()
                .ToArray();
            foreach (var requestId in requestIds)
            {
                _pendingIncomingActionsByRequestId.Remove(requestId);
            }
        }

        foreach (var timer in timers)
        {
            timer.Dispose();
        }
    }

    private void EnsurePeerCanUseNotificationSync(string deviceId)
    {
        var presence = _presenceService.GetPeerPresence(deviceId);
        if (presence is null ||
            !string.Equals(presence.Status, "online", StringComparison.OrdinalIgnoreCase) ||
            !presence.Capabilities.Contains(RequiredCapability, StringComparer.Ordinal) ||
            !_transport.HasActiveSession(deviceId))
        {
            throw new NotificationSyncFailureException(
                $"Capability '{RequiredCapability}' is not available for peer '{deviceId}'.",
                -32003);
        }
    }

    private NotificationSyncRecord NormalizeNotificationRecord(NotificationSyncRecord notification)
    {
        return new NotificationSyncRecord
        {
            NotificationId = notification.NotificationId,
            SourceDeviceId = notification.SourceDeviceId,
            SourcePlatform = notification.SourcePlatform,
            PackageName = notification.PackageName,
            AppName = notification.AppName,
            Title = notification.Title,
            BodyPreview = notification.BodyPreview,
            PostedAt = notification.PostedAt,
            IsDismissible = notification.IsDismissible,
            IsOpenable = notification.IsOpenable,
            IsRemoved = notification.IsRemoved,
            RemovedAt = notification.RemovedAt,
            Icon = NormalizeNotificationIcon(notification.Icon, notification.NotificationId)
        };
    }

    private IReadOnlyDictionary<string, object?>? NormalizeNotificationIcon(
        IReadOnlyDictionary<string, object?>? icon,
        string notificationId)
    {
        if (icon is null)
        {
            return null;
        }

        var normalized = NotificationIconNormalizer.Normalize(icon);
        if (normalized is null)
        {
            _logger.LogWarning(
                "Ignoring malformed notification icon for notification {NotificationId}.",
                notificationId);
        }

        return normalized;
    }

    private static void ValidateNotification(NotificationSyncRecord notification)
    {
        if (string.IsNullOrWhiteSpace(notification.NotificationId) ||
            string.IsNullOrWhiteSpace(notification.SourceDeviceId) ||
            string.IsNullOrWhiteSpace(notification.PackageName) ||
            string.IsNullOrWhiteSpace(notification.AppName) ||
            string.IsNullOrWhiteSpace(notification.PostedAt))
        {
            throw new InvalidOperationException("Mirrored notifications require notificationId, sourceDeviceId, packageName, appName, and postedAt.");
        }
    }

    private static string NormalizeAction(string action)
    {
        if (TryNormalizeAction(action, out var normalized))
        {
            return normalized;
        }

        throw new NotificationSyncFailureException($"Unknown notification action '{action}'.", -32010);
    }

    private static bool TryNormalizeAction(string action, out string normalized)
    {
        if (string.Equals(action, "open", StringComparison.Ordinal))
        {
            normalized = "open";
            return true;
        }

        if (string.Equals(action, "dismiss", StringComparison.Ordinal))
        {
            normalized = "dismiss";
            return true;
        }

        normalized = string.Empty;
        return false;
    }

    private static string? NormalizeFailureReason(
        bool success,
        string? failureReason,
        int? invalidErrorCode)
    {
        if (failureReason is not null)
        {
            if (FailureReasons.Contains(failureReason))
            {
                return success ? null : failureReason;
            }
            if (invalidErrorCode.HasValue)
            {
                throw new NotificationSyncFailureException(
                    $"Invalid failureReason '{failureReason}'.",
                    invalidErrorCode.Value);
            }
            return success ? null : "PeerRejected";
        }

        return success ? null : "PeerRejected";
    }

    private static void ValidateOptionalAuditTimestamp(string? value, string fieldName)
    {
        if (value is not null &&
            (!Rfc3339UtcTimestamp.IsMatch(value) ||
             !DateTimeOffset.TryParse(
                 value,
                 CultureInfo.InvariantCulture,
                 DateTimeStyles.None,
                 out var timestamp) ||
             timestamp.Offset != TimeSpan.Zero))
        {
            throw new NotificationSyncFailureException(
                $"{fieldName} must be a full RFC 3339 UTC timestamp.",
                -32602);
        }
    }

    private static string? LimitMessage(string? message) =>
        message is null || message.Length <= 1024 ? message : message[..1024];

    private static string GetNotificationKey(string sourceDeviceId, string notificationId) =>
        $"{sourceDeviceId}\n{notificationId}";

    private static string GetPendingActionKey(string sourceDeviceId, string notificationId, string action) =>
        $"{sourceDeviceId}\n{notificationId}\n{action}";

    private static object CreateNotificationPayload(NotificationSyncRecord notification) => new
    {
        notificationId = notification.NotificationId,
        sourceDeviceId = notification.SourceDeviceId,
        sourcePlatform = notification.SourcePlatform,
        packageName = notification.PackageName,
        appName = notification.AppName,
        title = notification.Title,
        bodyPreview = notification.BodyPreview,
        postedAt = notification.PostedAt,
        isDismissible = notification.IsDismissible,
        isOpenable = notification.IsOpenable,
        icon = notification.Icon
    };

    private object CreateEnvelope(string type, object payload) => new
    {
        rift = "0.1-draft",
        type,
        messageId = Guid.NewGuid().ToString("D"),
        sourceDeviceId = _identityManager.GetDeviceId(),
        payload
    };

    private async Task SendIncomingActionResultAsync(
        PendingIncomingNotificationAction pending,
        bool success,
        string? failureReason,
        string? message,
        CancellationToken cancellationToken)
    {
        var envelope = CreateEnvelope(
            "notification.actionResult",
            new
            {
                operationId = pending.OperationId,
                notificationId = pending.NotificationId,
                sourceDeviceId = pending.SourceDeviceId,
                requestingDeviceId = pending.RequestingDeviceId,
                action = pending.Action,
                success,
                failureReason,
                message
            });
        var bytes = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(envelope));
        await _transport.SendAsync(pending.RequestingDeviceId, bytes, cancellationToken).ConfigureAwait(false);
    }

    private async Task ExpireIncomingActionAsync(string requestId)
    {
        PendingIncomingNotificationAction? pending;
        lock (_gate)
        {
            if (!_pendingIncomingActionsByRequestId.Remove(requestId, out pending))
            {
                return;
            }
            if (_pendingIncomingActionTimers.Remove(requestId, out var timer))
            {
                timer.Dispose();
            }
        }

        try
        {
            await SendIncomingActionResultAsync(
                pending,
                success: false,
                failureReason: "Timeout",
                message: "The local notification action client did not handle the request.",
                CancellationToken.None).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Failed to expire incoming notification action {RequestId}.", requestId);
        }
    }

    private IReadOnlyDictionary<string, object?> CreateOperationDetails(NotificationSyncRecord notification, string action) =>
        new Dictionary<string, object?>
        {
            ["notificationId"] = notification.NotificationId,
            ["sourceDeviceId"] = notification.SourceDeviceId,
            ["packageName"] = notification.PackageName,
            ["action"] = action
        };

    private async Task<IReadOnlyList<string>> BroadcastNotificationAsync(
        string messageType,
        object payload,
        CancellationToken cancellationToken)
    {
        var sentTo = new List<string>();
        foreach (var peer in _presenceService.ListPeers())
        {
            if (!string.Equals(peer.Status, "online", StringComparison.OrdinalIgnoreCase) ||
                !peer.Capabilities.Contains(RequiredCapability, StringComparer.Ordinal) ||
                !_transport.HasActiveSession(peer.DeviceId))
            {
                continue;
            }

            try
            {
                var bytes = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(CreateEnvelope(messageType, payload)));
                await _transport.SendAsync(peer.DeviceId, bytes, cancellationToken).ConfigureAwait(false);
                sentTo.Add(peer.DeviceId);
            }
            catch (Exception ex)
            {
                _logger.LogWarning(ex, "Failed to send {MessageType} to {PeerDeviceId}.", messageType, peer.DeviceId);
            }
        }

        return sentTo;
    }

    private bool ShouldSyncNotification(string packageName)
    {
        lock (_gate)
        {
            if (!_policy.Enabled)
            {
                return false;
            }

            return _policy.Mode switch
            {
                NotificationSyncPolicyModes.All => true,
                NotificationSyncPolicyModes.Exclude => !_policy.PackageNames.Contains(
                    packageName,
                    StringComparer.Ordinal),
                NotificationSyncPolicyModes.Include => _policy.PackageNames.Contains(
                    packageName,
                    StringComparer.Ordinal),
                _ => false
            };
        }
    }

    private NotificationSyncRecord NormalizeLocalNotification(NotificationSyncRecord notification)
    {
        return new NotificationSyncRecord
        {
            NotificationId = notification.NotificationId,
            SourceDeviceId = string.IsNullOrWhiteSpace(notification.SourceDeviceId)
                ? _identityManager.GetDeviceId()
                : notification.SourceDeviceId,
            SourcePlatform = string.IsNullOrWhiteSpace(notification.SourcePlatform)
                ? DetectLocalPlatform()
                : notification.SourcePlatform,
            PackageName = notification.PackageName,
            AppName = notification.AppName,
            Title = notification.Title,
            BodyPreview = notification.BodyPreview,
            PostedAt = notification.PostedAt,
            IsDismissible = notification.IsDismissible,
            IsOpenable = notification.IsOpenable,
            IsRemoved = notification.IsRemoved,
            RemovedAt = notification.RemovedAt,
            Icon = NormalizeNotificationIcon(notification.Icon, notification.NotificationId)
        };
    }

    private static string DetectLocalPlatform() =>
        OperatingSystem.IsWindows() ? "windows" :
        OperatingSystem.IsMacOS() ? "macos" :
        OperatingSystem.IsLinux() ? "linux" :
        "unknown";

    private void TryTransitionActive(string operationId)
    {
        try
        {
            _operationService.TransitionOperation(operationId, OperationState.Active);
        }
        catch (OperationTransitionException)
        {
        }
    }

    private async Task NotifyIpcAsync(string method, object payload)
    {
        if (_ipcNotificationService is null)
        {
            return;
        }

        try
        {
            await _ipcNotificationService.NotifyAsync(method, payload).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Failed to notify IPC clients about {Method}.", method);
        }
    }

    private async Task LogEventAsync(
        string eventType,
        string? peerDeviceId,
        SecurityEventOutcome outcome,
        string? failureReason,
        IDictionary<string, object?> details)
    {
        try
        {
            await _securityEventLog.LogEventAsync(new SecurityEventRecord
            {
                EventType = eventType,
                Severity = outcome == SecurityEventOutcome.Failure ? SecurityEventSeverity.Warning : SecurityEventSeverity.Info,
                LocalDeviceId = _identityManager.GetDeviceId(),
                PeerDeviceId = peerDeviceId,
                Outcome = outcome,
                FailureReason = failureReason,
                Details = details
                    .Where(entry => entry.Value is not null)
                    .ToDictionary(
                        entry => entry.Key,
                        entry => entry.Value!)
            }).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to persist notification sync event {EventType}.", eventType);
        }
    }

    private static NotificationSyncPolicy ClonePolicy(NotificationSyncPolicy policy)
    {
        return new NotificationSyncPolicy
        {
            Enabled = policy.Enabled,
            Mode = policy.Mode,
            PackageNames = policy.PackageNames.ToArray()
        };
    }

    private static NotificationSyncObservedApp CloneObservedApp(NotificationSyncObservedApp app) => new()
    {
        PackageName = app.PackageName,
        AppName = app.AppName
    };

    private void ObserveLocalNotificationApp(NotificationSyncRecord notification)
    {
        lock (_gate)
        {
            _observedAppsByPackage[notification.PackageName] = new NotificationSyncObservedApp
            {
                PackageName = notification.PackageName,
                AppName = notification.AppName
            };
        }
    }

    private static NotificationSyncRecord CloneRecord(
        NotificationSyncRecord notification,
        bool? isDismissible = null,
        bool? isOpenable = null)
    {
        return new NotificationSyncRecord
        {
            NotificationId = notification.NotificationId,
            SourceDeviceId = notification.SourceDeviceId,
            SourcePlatform = notification.SourcePlatform,
            PackageName = notification.PackageName,
            AppName = notification.AppName,
            Title = notification.Title,
            BodyPreview = notification.BodyPreview,
            PostedAt = notification.PostedAt,
            IsDismissible = isDismissible ?? notification.IsDismissible,
            IsOpenable = isOpenable ?? notification.IsOpenable,
            IsRemoved = notification.IsRemoved,
            RemovedAt = notification.RemovedAt,
            Icon = notification.Icon is null ? null : new Dictionary<string, object?>(notification.Icon)
        };
    }

    private sealed record PendingNotificationAction(
        string OperationId,
        string NotificationId,
        string SourceDeviceId,
        string Action)
    {
        public Timer? ExpiryTimer { get; set; }
    }

    private PendingNotificationAction? RemovePendingAction(
        string operationId,
        string sourceDeviceId,
        string notificationId,
        string action)
    {
        lock (_gate)
        {
            _pendingActionsByOperationId.Remove(operationId, out var pending);
            var actionKey = GetPendingActionKey(sourceDeviceId, notificationId, action);
            if (_pendingActionKeys.GetValueOrDefault(actionKey) == operationId)
            {
                _pendingActionKeys.Remove(actionKey);
            }

            return pending;
        }
    }

    private void ExpirePendingAction(string operationId)
    {
        PendingNotificationAction? pending;
        lock (_gate)
        {
            if (!_pendingActionsByOperationId.Remove(operationId, out pending))
            {
                return;
            }

            var actionKey = GetPendingActionKey(pending.SourceDeviceId, pending.NotificationId, pending.Action);
            if (_pendingActionKeys.GetValueOrDefault(actionKey) == operationId)
            {
                _pendingActionKeys.Remove(actionKey);
            }
        }

        pending.ExpiryTimer?.Dispose();
        try
        {
            _operationService.TransitionOperation(operationId, OperationState.Expired, "Timeout");
        }
        catch (Exception ex)
        {
            // Timer-thread callback: an unhandled exception here would crash the
            // whole daemon process, so expiry bookkeeping failures are logged only.
            _logger.LogWarning(ex, "Failed to expire pending notification action {OperationId}.", operationId);
        }
    }
}
