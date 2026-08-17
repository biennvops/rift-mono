namespace Rift.Daemon.Core.Interfaces;

public sealed class LocalNotificationActionResult
{
    public bool Success { get; init; }
    public string? FailureReason { get; init; }
    public string? Message { get; init; }
}

public interface ILocalNotificationActionHandler
{
    bool CanPerform(NotificationSyncRecord notification, string action);

    Task<LocalNotificationActionResult> PerformAsync(
        NotificationSyncRecord notification,
        string action,
        CancellationToken cancellationToken);
}
