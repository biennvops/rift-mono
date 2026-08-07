namespace Rift.Daemon.Core.Interfaces;

public static class NotificationSyncPolicyModes
{
    public const string All = "all";
    public const string Exclude = "exclude";
    public const string Include = "include";

    public static bool IsValid(string? mode) => mode is All or Exclude or Include;

    public static string Validate(string? mode)
    {
        if (!IsValid(mode))
        {
            throw new NotificationSyncFailureException(
                $"Notification sync policy mode must be '{All}', '{Exclude}', or '{Include}'.",
                -32602);
        }

        return mode!;
    }

    public static IReadOnlyList<string> NormalizePackageNames(IEnumerable<string?> values)
    {
        if (values.Any(value => value is null))
        {
            throw new NotificationSyncFailureException(
                "Notification sync policy packageNames must contain only strings.",
                -32602);
        }

        return values
            .Where(value => !string.IsNullOrWhiteSpace(value))
            .Select(value => value!.Trim())
            .Distinct(StringComparer.Ordinal)
            .Order(StringComparer.Ordinal)
            .ToArray();
    }
}

public sealed class NotificationSyncPolicy
{
    public bool Enabled { get; init; } = true;
    public string Mode { get; init; } = NotificationSyncPolicyModes.All;
    public IReadOnlyList<string> PackageNames { get; init; } = [];
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

public sealed class NotificationSyncObservedApp
{
    public string PackageName { get; init; } = string.Empty;
    public string AppName { get; init; } = string.Empty;
}

public sealed class ListNotificationsResult
{
    public IReadOnlyList<NotificationSyncRecord> Notifications { get; init; } = [];
    public IReadOnlyList<NotificationSyncObservedApp> ObservedApps { get; init; } = [];
    public NotificationSyncPolicy Policy { get; init; } = new();
}

public sealed class PerformNotificationActionResult
{
    public string OperationId { get; init; } = string.Empty;
    public string SourceDeviceId { get; init; } = string.Empty;
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
        string sourceDeviceId,
        string notificationId,
        string action,
        CancellationToken cancellationToken);

    Task<NotificationSyncPolicy> UpdateNotificationSyncPolicyAsync(
        bool enabled,
        string mode,
        IReadOnlyList<string> packageNames,
        CancellationToken cancellationToken);

    Task HandleNotificationPostedAsync(NotificationSyncRecord notification, CancellationToken cancellationToken);

    Task HandleNotificationUpdatedAsync(NotificationSyncRecord notification, CancellationToken cancellationToken);

    Task HandleNotificationRemovedAsync(NotificationRemovedRecord notification, CancellationToken cancellationToken);

    Task HandleNotificationActionResultAsync(NotificationActionResultRecord result, CancellationToken cancellationToken);
}
