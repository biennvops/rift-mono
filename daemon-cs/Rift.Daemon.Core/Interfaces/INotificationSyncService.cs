namespace Rift.Daemon.Core.Interfaces;

public sealed class NotificationSyncPolicy
{
    public bool Enabled { get; init; }
    public IReadOnlyList<string> BlacklistedPackages { get; init; } = [];
}

public sealed class NotificationSyncRecord
{
    public string NotificationId { get; init; } = string.Empty;
    public string SourceDeviceId { get; init; } = string.Empty;
    public string? SourcePlatform { get; init; }
    public string PackageName { get; init; } = string.Empty;
    public string AppName { get; init; } = string.Empty;
    public string? Title { get; init; }
    public string? BodyPreview { get; init; }
    public string PostedAt { get; init; } = string.Empty;
    public bool IsDismissible { get; init; }
    public bool IsOpenable { get; init; }
    public bool IsRemoved { get; init; }
    public string? RemovedAt { get; init; }
    public IReadOnlyDictionary<string, object?>? Icon { get; init; }
}

public sealed class ListNotificationsResult
{
    public IReadOnlyList<NotificationSyncRecord> Notifications { get; init; } = [];
    public NotificationSyncPolicy Policy { get; init; } = new();
}

public sealed class PerformNotificationActionResult
{
    public string OperationId { get; init; } = string.Empty;
    public string NotificationId { get; init; } = string.Empty;
    public string Action { get; init; } = string.Empty;
    public string State { get; init; } = string.Empty;
}

public sealed class NotifyLocalNotificationEventResult
{
    public string NotificationId { get; init; } = string.Empty;
    public IReadOnlyList<string> BroadcastTo { get; init; } = [];
    public bool Suppressed { get; init; }
}

public sealed class NotificationRemovedRecord
{
    public string NotificationId { get; init; } = string.Empty;
    public string SourceDeviceId { get; init; } = string.Empty;
    public string? RemovedAt { get; init; }
}

public sealed class NotificationActionResultRecord
{
    public string NotificationId { get; init; } = string.Empty;
    public string SourceDeviceId { get; init; } = string.Empty;
    public string RequestingDeviceId { get; init; } = string.Empty;
    public string Action { get; init; } = string.Empty;
    public bool Success { get; init; }
    public string? FailureReason { get; init; }
    public string? Message { get; init; }
}

public interface INotificationSyncService
{
    Task<NotifyLocalNotificationEventResult> HandleLocalNotificationEventAsync(
        string eventType,
        NotificationSyncRecord notification,
        string? removedAt,
        CancellationToken cancellationToken);

    Task<ListNotificationsResult> ListNotificationsAsync(CancellationToken cancellationToken);

    Task<PerformNotificationActionResult> PerformNotificationActionAsync(
        string notificationId,
        string action,
        CancellationToken cancellationToken);

    Task<NotificationSyncPolicy> UpdateNotificationSyncPolicyAsync(
        bool enabled,
        IReadOnlyList<string> blacklistedPackages,
        CancellationToken cancellationToken);

    Task HandleNotificationPostedAsync(NotificationSyncRecord notification, CancellationToken cancellationToken);

    Task HandleNotificationUpdatedAsync(NotificationSyncRecord notification, CancellationToken cancellationToken);

    Task HandleNotificationRemovedAsync(NotificationRemovedRecord notification, CancellationToken cancellationToken);

    Task HandleNotificationActionResultAsync(NotificationActionResultRecord result, CancellationToken cancellationToken);
}
