using Rift.Daemon.Core.Interfaces;

namespace Rift.Daemon.macOS;

internal sealed class MacOSNotificationSyncObserver(
    IMacOSNotificationExtractorClient extractorClient,
    INotificationSyncService notificationSyncService,
    IIdentityManager identityManager,
    ILogger<MacOSNotificationSyncObserver> logger) : BackgroundService
{
    private const int ExtractorPageSize = 500;
    private static readonly TimeSpan PollInterval = TimeSpan.FromSeconds(2);
    private static readonly TimeSpan RetryInterval = TimeSpan.FromSeconds(30);

    private readonly Dictionary<string, string> _fingerprints = new(StringComparer.Ordinal);
    private long _cursor;
    private bool _cursorInitialized;

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                await BootstrapAsync(stoppingToken).ConfigureAwait(false);
                await PollAsync(stoppingToken).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
            {
                break;
            }
            catch (MacOSExtractorException ex)
            {
                logger.LogWarning(
                    "macOS notification extraction unavailable ({Code}): {Message}",
                    ex.Code,
                    ex.Message);
            }
            catch (Exception ex)
            {
                logger.LogWarning(ex, "macOS notification extraction failed.");
            }

            try
            {
                await Task.Delay(RetryInterval, stoppingToken).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
            {
                break;
            }
        }
    }

    internal async Task BootstrapAsync(CancellationToken cancellationToken)
    {
        var status = await extractorClient.GetStatusAsync(cancellationToken).ConfigureAwait(false);
        if (!string.Equals(status.State, "ready", StringComparison.Ordinal) ||
            !status.DatabaseReadable ||
            !status.SchemaSupported)
        {
            throw new MacOSExtractorException(status.State, GetStatusMessage(status.State));
        }

        if (!_cursorInitialized)
        {
            _cursor = 0;
            for (var page = 0; page < 10_000; page++)
            {
                var scan = await extractorClient.ScanNotificationChangesAsync(_cursor, cancellationToken).ConfigureAwait(false);
                _cursor = Math.Max(_cursor, scan.Cursor);
                if (scan.Notifications.Count + scan.SkippedRecords < ExtractorPageSize)
                {
                    break;
                }
                if (page == 9_999)
                {
                    throw new MacOSExtractorException("bootstrapLimitExceeded", "Notification cursor bootstrap exceeded its safety limit.");
                }
            }
            _cursorInitialized = true;
        }

        logger.LogInformation("macOS notification extraction started at cursor {Cursor}.", _cursor);
    }

    private async Task PollAsync(CancellationToken cancellationToken)
    {
        while (!cancellationToken.IsCancellationRequested)
        {
            var scan = await extractorClient.ScanNotificationChangesAsync(_cursor, cancellationToken).ConfigureAwait(false);
            _cursor = Math.Max(_cursor, scan.Cursor);
            if (scan.Notifications.Count > 0 || scan.SkippedRecords > 0)
            {
                logger.LogInformation(
                    "macOS notification scan returned {NotificationCount} records and skipped {SkippedCount} at cursor {Cursor}.",
                    scan.Notifications.Count,
                    scan.SkippedRecords,
                    _cursor);
            }
            await ProcessIncrementalAsync(scan.Notifications, cancellationToken).ConfigureAwait(false);
            await Task.Delay(PollInterval, cancellationToken).ConfigureAwait(false);
        }
    }

    internal async Task ProcessIncrementalAsync(
        IReadOnlyList<MacOSExtractedNotification> notifications,
        CancellationToken cancellationToken)
    {
        foreach (var notification in notifications)
        {
            if (ShouldIgnore(notification.PackageName))
            {
                continue;
            }

            var fingerprint = CreateFingerprint(notification);
            var eventType = _fingerprints.ContainsKey(notification.NotificationId) ? "updated" : "posted";
            if (_fingerprints.TryGetValue(notification.NotificationId, out var previousFingerprint) &&
                string.Equals(previousFingerprint, fingerprint, StringComparison.Ordinal))
            {
                continue;
            }

            _fingerprints[notification.NotificationId] = fingerprint;
            var result = await PublishAsync(eventType, notification, removedAt: null, cancellationToken).ConfigureAwait(false);
            logger.LogInformation(
                "macOS notification {EventType} processed (suppressed={Suppressed}, broadcastPeers={BroadcastPeerCount}).",
                eventType,
                result.Suppressed,
                result.BroadcastTo.Count);
        }
    }

    private Task<NotifyLocalNotificationEventResult> PublishAsync(
        string eventType,
        MacOSExtractedNotification notification,
        string? removedAt,
        CancellationToken cancellationToken) =>
        notificationSyncService.HandleLocalNotificationEventAsync(
            eventType,
            new NotificationSyncRecord
            {
                NotificationId = notification.NotificationId,
                SourceDeviceId = identityManager.GetDeviceId(),
                SourcePlatform = "macos",
                PackageName = notification.PackageName,
                AppName = notification.AppName,
                Title = notification.Title,
                BodyPreview = notification.BodyPreview,
                PostedAt = notification.PostedAt,
                IsDismissible = false,
                IsOpenable = false
            },
            removedAt,
            cancellationToken);

    private static bool ShouldIgnore(string packageName) =>
        string.Equals(packageName, "com.example.appFlutter", StringComparison.OrdinalIgnoreCase) ||
        packageName.StartsWith("com.rift.", StringComparison.OrdinalIgnoreCase);

    private static string CreateFingerprint(MacOSExtractedNotification notification) => string.Join(
        '\n',
        notification.PackageName,
        notification.AppName,
        notification.Title ?? string.Empty,
        notification.BodyPreview ?? string.Empty,
        notification.PostedAt);

    private static string GetStatusMessage(string state) => state switch
    {
        "databaseNotFound" => "The macOS Notification Center database was not found.",
        "fullDiskAccessRequired" => "Full Disk Access is required for Rift Notification Extractor.",
        "unsupportedSchema" => "The macOS Notification Center schema is not supported.",
        _ => "Rift Notification Extractor is not ready."
    };
}
