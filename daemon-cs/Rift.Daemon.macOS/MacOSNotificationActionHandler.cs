using Rift.Daemon.Core.Interfaces;

namespace Rift.Daemon.macOS;

internal sealed class MacOSNotificationActionHandler(
    IMacOSNotificationExtractorClient extractorClient,
    ILogger<MacOSNotificationActionHandler> logger) : ILocalNotificationActionHandler
{
    public bool CanPerform(NotificationSyncRecord notification, string action) =>
        notification.IsDismissible &&
        string.Equals(action, "dismiss", StringComparison.Ordinal) &&
        string.Equals(notification.SourcePlatform, "macos", StringComparison.OrdinalIgnoreCase);

    public async Task<LocalNotificationActionResult> PerformAsync(
        NotificationSyncRecord notification,
        string action,
        CancellationToken cancellationToken)
    {
        if (!CanPerform(notification, action))
        {
            return Unavailable("The macOS notification is not currently dismissible.");
        }

        try
        {
            var capabilities = await extractorClient.GetNotificationActionCapabilitiesAsync(
                    notification.NotificationId,
                    notification.PackageName,
                    cancellationToken)
                .ConfigureAwait(false);
            if (!capabilities.CanDismiss)
            {
                return Unavailable("The exact macOS notification is no longer individually actionable.");
            }

            var result = await extractorClient.DismissNotificationAsync(
                    notification.NotificationId,
                    notification.PackageName,
                    cancellationToken)
                .ConfigureAwait(false);
            return result.Success
                ? new LocalNotificationActionResult { Success = true }
                : Unavailable("The exact macOS notification could not be dismissed and verified.");
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception ex)
        {
            logger.LogDebug(
                ex,
                "macOS notification dismissal failed for {NotificationId}.",
                notification.NotificationId);
            return Unavailable("The exact macOS notification could not be dismissed and verified.");
        }
    }

    private static LocalNotificationActionResult Unavailable(string message) => new()
    {
        Success = false,
        FailureReason = "CapabilityUnavailable",
        Message = message
    };
}
