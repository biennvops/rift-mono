using System.Text;
using System.Text.Json;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;
using Rift.Daemon.Core.Interfaces;

namespace Rift.Daemon.Core;

public sealed class NotificationSyncService : INotificationSyncService
{
    private const string RequiredCapability = "notification.sync";
    private readonly Lock _gate = new();
    private readonly ITransport _transport;
    private readonly IPresenceService _presenceService;
    private readonly IIdentityManager _identityManager;
    private readonly IOperationService _operationService;
    private readonly ISecurityEventLog _securityEventLog;
    private readonly IIpcNotificationService? _ipcNotificationService;
    private readonly ILogger<NotificationSyncService> _logger;
    private readonly Dictionary<string, NotificationSyncRecord> _notifications = new(StringComparer.Ordinal);
    private readonly Dictionary<string, PendingNotificationAction> _pendingActionsByOperationId = new(StringComparer.Ordinal);
    private readonly Dictionary<string, string> _pendingActionKeys = new(StringComparer.Ordinal);
    private NotificationSyncPolicy _policy = new()
    {
        Enabled = true,
        BlacklistedPackages = []
    };

    public NotificationSyncService(
        ITransport transport,
        IPresenceService presenceService,
        IIdentityManager identityManager,
        IOperationService operationService,
        ISecurityEventLog securityEventLog,
        IIpcNotificationService? ipcNotificationService = null,
        ILogger<NotificationSyncService>? logger = null)
    {
        _transport = transport;
        _presenceService = presenceService;
        _identityManager = identityManager;
        _operationService = operationService;
        _securityEventLog = securityEventLog;
        _ipcNotificationService = ipcNotificationService;
        _logger = logger ?? NullLogger<NotificationSyncService>.Instance;
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
                    .Select(CloneRecord)
                    .ToArray(),
                Policy = ClonePolicy(_policy)
            });
        }
    }

    public async Task<NotifyLocalNotificationEventResult> HandleLocalNotificationEventAsync(
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

        var suppressed = IsNotificationSuppressed(normalizedNotification.PackageName);
        if (suppressed &&
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
            new
            {
                notificationId = normalizedNotification.NotificationId,
                sourceDeviceId = normalizedNotification.SourceDeviceId,
                sourcePlatform = normalizedNotification.SourcePlatform,
                packageName = normalizedNotification.PackageName,
                appName = normalizedNotification.AppName,
                title = normalizedNotification.Title,
                bodyPreview = normalizedNotification.BodyPreview,
                postedAt = normalizedNotification.PostedAt,
                isDismissible = normalizedNotification.IsDismissible,
                isOpenable = normalizedNotification.IsOpenable,
                icon = normalizedNotification.Icon
            },
            cancellationToken).ConfigureAwait(false);

        return new NotifyLocalNotificationEventResult
        {
            NotificationId = normalizedNotification.NotificationId,
            BroadcastTo = broadcastTo,
            Suppressed = suppressed
        };
    }

    public async Task<PerformNotificationActionResult> PerformNotificationActionAsync(
        string sourceDeviceId,
        string notificationId,
        string action,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();

        if (string.IsNullOrWhiteSpace(sourceDeviceId) || string.IsNullOrWhiteSpace(notificationId))
        {
            throw new NotificationSyncFailureException("A source device ID and notification ID are required.", -32009);
        }

        var normalizedAction = NormalizeAction(action);
        NotificationSyncRecord notification;
        lock (_gate)
        {
            notification = _notifications.GetValueOrDefault(GetNotificationKey(sourceDeviceId, notificationId))
                ?? throw new NotificationSyncFailureException($"Mirrored notification '{notificationId}' was not found for '{sourceDeviceId}'.", -32009);
            if (notification.IsRemoved)
            {
                throw new NotificationSyncFailureException($"Mirrored notification '{notificationId}' was not found for '{sourceDeviceId}'.", -32009);
            }
        }

        EnsureActionAllowed(notification, normalizedAction);
        EnsurePeerCanUseNotificationSync(notification.SourceDeviceId);

        var operationId = Guid.NewGuid().ToString("D");
        var operationType = normalizedAction == "open" ? "notification.open" : "notification.dismiss";
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
            _pendingActionKeys[GetPendingActionKey(notification.SourceDeviceId, notification.NotificationId, normalizedAction)] = operationId;
        }
        _operationService.TransitionOperation(operationId, OperationState.Dispatched);

        var envelope = CreateEnvelope(
            "notification.actionRequest",
            new
            {
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
            RemovePendingAction(operationId, notification.SourceDeviceId, notification.NotificationId, normalizedAction);
            _operationService.TransitionOperation(operationId, OperationState.Failed, "PeerUnreachable");
            throw new NotificationSyncFailureException($"Failed to send notification action request: {ex.Message}", -32003);
        }

        return new PerformNotificationActionResult
        {
            OperationId = operationId,
            NotificationId = notification.NotificationId,
            Action = normalizedAction,
            State = "Pending"
        };
    }

    public Task<NotificationSyncPolicy> UpdateNotificationSyncPolicyAsync(
        bool enabled,
        IReadOnlyList<string> blacklistedPackages,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();

        var normalized = blacklistedPackages
            .Where(packageName => !string.IsNullOrWhiteSpace(packageName))
            .Select(packageName => packageName.Trim())
            .Distinct(StringComparer.Ordinal)
            .ToArray();

        lock (_gate)
        {
            _policy = new NotificationSyncPolicy
            {
                Enabled = enabled,
                BlacklistedPackages = normalized
            };

            return Task.FromResult(ClonePolicy(_policy));
        }
    }

    public async Task HandleNotificationPostedAsync(NotificationSyncRecord notification, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        ValidateNotification(notification);

        lock (_gate)
        {
            var stored = CloneRecord(notification);
            stored = new NotificationSyncRecord
            {
                NotificationId = stored.NotificationId,
                SourceDeviceId = stored.SourceDeviceId,
                SourcePlatform = stored.SourcePlatform,
                PackageName = stored.PackageName,
                AppName = stored.AppName,
                Title = stored.Title,
                BodyPreview = stored.BodyPreview,
                PostedAt = stored.PostedAt,
                IsDismissible = stored.IsDismissible,
                IsOpenable = stored.IsOpenable,
                Icon = stored.Icon is null ? null : new Dictionary<string, object?>(stored.Icon)
            };
            _notifications[GetNotificationKey(notification.SourceDeviceId, notification.NotificationId)] = stored;
        }

        await NotifyIpcAsync("rift.onNotificationPosted", notification).ConfigureAwait(false);
        await LogEventAsync(SecurityEventTypes.NotificationSynced, notification.SourceDeviceId, SecurityEventOutcome.Success, null, new Dictionary<string, object?>
        {
            ["notificationId"] = notification.NotificationId,
            ["packageName"] = notification.PackageName
        }).ConfigureAwait(false);
    }

    public async Task HandleNotificationUpdatedAsync(NotificationSyncRecord notification, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        ValidateNotification(notification);

        lock (_gate)
        {
            var stored = CloneRecord(notification);
            stored = new NotificationSyncRecord
            {
                NotificationId = stored.NotificationId,
                SourceDeviceId = stored.SourceDeviceId,
                SourcePlatform = stored.SourcePlatform,
                PackageName = stored.PackageName,
                AppName = stored.AppName,
                Title = stored.Title,
                BodyPreview = stored.BodyPreview,
                PostedAt = stored.PostedAt,
                IsDismissible = stored.IsDismissible,
                IsOpenable = stored.IsOpenable,
                Icon = stored.Icon is null ? null : new Dictionary<string, object?>(stored.Icon)
            };
            _notifications[GetNotificationKey(notification.SourceDeviceId, notification.NotificationId)] = stored;
        }

        await NotifyIpcAsync("rift.onNotificationUpdated", notification).ConfigureAwait(false);
        await LogEventAsync(SecurityEventTypes.NotificationSynced, notification.SourceDeviceId, SecurityEventOutcome.Success, null, new Dictionary<string, object?>
        {
            ["notificationId"] = notification.NotificationId,
            ["packageName"] = notification.PackageName,
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

        NotificationSyncRecord updated;
        lock (_gate)
        {
            var key = GetNotificationKey(notification.SourceDeviceId, notification.NotificationId);
            if (_notifications.TryGetValue(key, out var existing))
            {
                updated = new NotificationSyncRecord
                {
                    NotificationId = existing.NotificationId,
                    SourceDeviceId = existing.SourceDeviceId,
                    SourcePlatform = existing.SourcePlatform,
                    PackageName = existing.PackageName,
                    AppName = existing.AppName,
                    Title = existing.Title,
                    BodyPreview = existing.BodyPreview,
                    PostedAt = existing.PostedAt,
                    IsDismissible = existing.IsDismissible,
                    IsOpenable = existing.IsOpenable,
                    IsRemoved = true,
                    RemovedAt = notification.RemovedAt ?? DateTimeOffset.UtcNow.ToString("O"),
                    Icon = existing.Icon is null ? null : new Dictionary<string, object?>(existing.Icon)
                };
            }
            else
            {
                updated = new NotificationSyncRecord
                {
                    NotificationId = notification.NotificationId,
                    SourceDeviceId = notification.SourceDeviceId,
                    PostedAt = notification.RemovedAt ?? DateTimeOffset.UtcNow.ToString("O"),
                    IsRemoved = true,
                    RemovedAt = notification.RemovedAt ?? DateTimeOffset.UtcNow.ToString("O")
                };
            }

            _notifications[key] = updated;
        }

        await NotifyIpcAsync("rift.onNotificationRemoved", new
        {
            notificationId = updated.NotificationId,
            sourceDeviceId = updated.SourceDeviceId,
            removedAt = updated.RemovedAt
        }).ConfigureAwait(false);
        await LogEventAsync(SecurityEventTypes.NotificationRemoved, updated.SourceDeviceId, SecurityEventOutcome.Success, null, new Dictionary<string, object?>
        {
            ["notificationId"] = updated.NotificationId
        }).ConfigureAwait(false);
    }

    public async Task HandleNotificationActionResultAsync(NotificationActionResultRecord result, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();

        if (!string.Equals(result.RequestingDeviceId, _identityManager.GetDeviceId(), StringComparison.Ordinal))
        {
            throw new InvalidOperationException("notification.actionResult requestingDeviceId did not match the local device identity.");
        }

        var action = NormalizeAction(result.Action);
        PendingNotificationAction pending;
        lock (_gate)
        {
            var pendingKey = GetPendingActionKey(result.SourceDeviceId, result.NotificationId, action);
            if (!_pendingActionKeys.TryGetValue(pendingKey, out var operationId) ||
                !_pendingActionsByOperationId.TryGetValue(operationId, out pending!))
            {
                throw new InvalidOperationException($"No pending notification action exists for '{result.NotificationId}' ({action}).");
            }

            _pendingActionsByOperationId.Remove(operationId);
            _pendingActionKeys.Remove(pendingKey);
        }

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

    private void EnsureActionAllowed(NotificationSyncRecord notification, string action)
    {
        var allowed = action switch
        {
            "open" => notification.IsOpenable,
            "dismiss" => notification.IsDismissible,
            _ => false
        };

        if (!allowed)
        {
            throw new NotificationSyncFailureException(
                $"Mirrored notification '{notification.NotificationId}' does not allow action '{action}'.",
                -32010);
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
        if (string.Equals(action, "open", StringComparison.Ordinal))
        {
            return "open";
        }

        if (string.Equals(action, "dismiss", StringComparison.Ordinal))
        {
            return "dismiss";
        }

        throw new NotificationSyncFailureException($"Unknown notification action '{action}'.", -32010);
    }

    private static string GetNotificationKey(string sourceDeviceId, string notificationId) =>
        $"{sourceDeviceId}\n{notificationId}";

    private static string GetPendingActionKey(string sourceDeviceId, string notificationId, string action) =>
        $"{sourceDeviceId}\n{notificationId}\n{action}";

    private object CreateEnvelope(string type, object payload) => new
    {
        rift = "0.1-draft",
        type,
        messageId = Guid.NewGuid().ToString("D"),
        sourceDeviceId = _identityManager.GetDeviceId(),
        payload
    };

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

    private bool IsNotificationSuppressed(string packageName)
    {
        lock (_gate)
        {
            return !_policy.Enabled ||
                _policy.BlacklistedPackages.Contains(packageName, StringComparer.Ordinal);
        }
    }

    private NotificationSyncRecord NormalizeLocalNotification(NotificationSyncRecord notification)
    {
        var sourcePlatform = DetectLocalPlatform();
        return new NotificationSyncRecord
        {
            NotificationId = notification.NotificationId,
            SourceDeviceId = string.IsNullOrWhiteSpace(notification.SourceDeviceId)
                ? _identityManager.GetDeviceId()
                : notification.SourceDeviceId,
            SourcePlatform = sourcePlatform,
            PackageName = notification.PackageName,
            AppName = notification.AppName,
            Title = notification.Title,
            BodyPreview = notification.BodyPreview,
            PostedAt = notification.PostedAt,
            IsDismissible = false,
            IsOpenable = false,
            IsRemoved = notification.IsRemoved,
            RemovedAt = notification.RemovedAt,
            Icon = notification.Icon is null ? null : new Dictionary<string, object?>(notification.Icon)
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
            BlacklistedPackages = policy.BlacklistedPackages.ToArray()
        };
    }

    private static NotificationSyncRecord CloneRecord(NotificationSyncRecord notification)
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
            Icon = notification.Icon is null ? null : new Dictionary<string, object?>(notification.Icon)
        };
    }

    private sealed record PendingNotificationAction(
        string OperationId,
        string NotificationId,
        string SourceDeviceId,
        string Action);

    private void RemovePendingAction(
        string operationId,
        string sourceDeviceId,
        string notificationId,
        string action)
    {
        lock (_gate)
        {
            _pendingActionsByOperationId.Remove(operationId);
            _pendingActionKeys.Remove(GetPendingActionKey(sourceDeviceId, notificationId, action));
        }
    }
}
