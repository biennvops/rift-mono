using Rift.Daemon.Core.Interfaces;

namespace Rift.Daemon.Linux;

internal sealed class LinuxNotificationActionHandler(
    LinuxNotificationRegistry registry,
    ILinuxNotificationControl control,
    ILogger<LinuxNotificationActionHandler> logger) : ILocalNotificationActionHandler
{
    public bool CanPerform(NotificationSyncRecord notification, string action) =>
        control.IsAvailable &&
        string.Equals(action, "dismiss", StringComparison.Ordinal) &&
        string.Equals(notification.SourcePlatform, "linux", StringComparison.Ordinal) &&
        registry.TryGet(notification.NotificationId, out _);

    public async Task<LocalNotificationActionResult> PerformAsync(
        NotificationSyncRecord notification,
        string action,
        CancellationToken cancellationToken)
    {
        if (!CanPerform(notification, action) ||
            !registry.TryBeginClosing(notification.NotificationId, out var target) ||
            target is null)
        {
            return new LocalNotificationActionResult
            {
                Success = false,
                FailureReason = "CapabilityUnavailable",
                Message = "The Linux notification is no longer available."
            };
        }

        try
        {
            var currentOwner = await control.GetNotificationServerOwnerAsync(cancellationToken)
                .ConfigureAwait(false);
            if (!string.Equals(
                    currentOwner,
                    target.NotificationServerOwner,
                    StringComparison.Ordinal))
            {
                registry.RestoreActive(target);
                return new LocalNotificationActionResult
                {
                    Success = false,
                    FailureReason = "CapabilityUnavailable",
                    Message = "The Linux notification server restarted."
                };
            }

            await control.CloseNotificationAsync(
                    target.NotificationServerOwner,
                    target.NativeNotificationId,
                    cancellationToken)
                .ConfigureAwait(false);
            return new LocalNotificationActionResult { Success = true };
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            registry.RestoreActive(target);
            throw;
        }
        catch (Exception ex)
        {
            registry.RestoreActive(target);
            logger.LogDebug(
                ex,
                "Failed to close Linux notification {NotificationId}.",
                notification.NotificationId);
            return new LocalNotificationActionResult
            {
                Success = false,
                FailureReason = "CapabilityUnavailable",
                Message = ex is TimeoutException
                    ? "The Linux notification close request timed out."
                    : "The Linux notification could not be closed."
            };
        }
    }
}
