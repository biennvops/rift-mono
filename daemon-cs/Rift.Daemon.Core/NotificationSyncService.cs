using System.Text;
using System.Text.Json;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;
using Rift.Daemon.Core.Interfaces;

namespace Rift.Daemon.Core;

public sealed class NotificationSyncService : INotificationSyncService
{
    private const string RequiredCapability = "notification.sync";
    private static readonly TimeSpan DefaultActionTimeout = TimeSpan.FromSeconds(30);
    private readonly Lock _gate = new();
    private readonly ITransport _transport;
    private readonly IPresenceService _presenceService;
    private readonly IIdentityManager _identityManager;
    private readonly IOperationService _operationService;
    private readonly ISecurityEventLog _securityEventLog;
    private readonly IIpcNotificationService? _ipcNotificationService;
    private readonly INotificationSyncPolicyStore? _policyStore;
    private readonly ILogger<NotificationSyncService> _logger;
    private readonly TimeSpan _actionTimeout;
    private readonly Dictionary<string, NotificationSyncRecord> _notifications = new(StringComparer.Ordinal);
    private readonly Dictionary<string, NotificationSyncObservedApp> _observedAppsByPackage = new(StringComparer.Ordinal);
    private readonly Dictionary<string, PendingNotificationAction> _pendingActionsByOperationId = new(StringComparer.Ordinal);
    private readonly Dictionary<string, string> _pendingActionKeys = new(StringComparer.Ordinal);
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
        TimeSpan? actionTimeout = null)
    {
        _transport = transport;
        _presenceService = presenceService;
        _identityManager = identityManager;
        _operationService = operationService;
        _securityEventLog = securityEventLog;
        _ipcNotificationService = ipcNotificationService;
        _policyStore = policyStore;
        _logger = logger ?? NullLogger<NotificationSyncService>.Instance;
        _actionTimeout = actionTimeout ?? DefaultActionTimeout;
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
                    .Select(CloneRecord)
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
            // Desktop hosts have no native notification action executor, so locally
            // originating records must not advertise actions this daemon cannot run.
            IsDismissible = false,
            IsOpenable = false,
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
