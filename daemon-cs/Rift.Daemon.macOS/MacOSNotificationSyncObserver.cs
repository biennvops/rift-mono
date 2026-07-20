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
    private static readonly TimeSpan ReconcileInterval = TimeSpan.FromSeconds(15);
    private static readonly TimeSpan RetryInterval = TimeSpan.FromSeconds(30);

    private readonly Dictionary<string, string> _fingerprints = new(StringComparer.Ordinal);
    private long _cursor;

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

    private async Task BootstrapAsync(CancellationToken cancellationToken)
    {
        var status = await extractorClient.GetStatusAsync(cancellationToken).ConfigureAwait(false);
        if (!string.Equals(status.State, "ready", StringComparison.Ordinal) ||
            !status.DatabaseReadable ||
            !status.SchemaSupported)
        {
            throw new MacOSExtractorException(status.State, GetStatusMessage(status.State));
        }

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

        var active = await extractorClient.RescanActiveNotificationsAsync(cancellationToken).ConfigureAwait(false);
        await ReconcileActiveAsync(active.Notifications, cancellationToken).ConfigureAwait(false);
        logger.LogInformation("macOS notification extraction started at cursor {Cursor}.", _cursor);
    }

    private async Task PollAsync(CancellationToken cancellationToken)
    {
        var nextReconcileAt = DateTimeOffset.UtcNow + ReconcileInterval;
        while (!cancellationToken.IsCancellationRequested)
        {
            var scan = await extractorClient.ScanNotificationChangesAsync(_cursor, cancellationToken).ConfigureAwait(false);
            _cursor = Math.Max(_cursor, scan.Cursor);
            await ProcessIncrementalAsync(scan.Notifications, cancellationToken).ConfigureAwait(false);

            if (DateTimeOffset.UtcNow >= nextReconcileAt)
            {
                var active = await extractorClient.RescanActiveNotificationsAsync(cancellationToken).ConfigureAwait(false);
                await ReconcileActiveAsync(active.Notifications, cancellationToken).ConfigureAwait(false);
                nextReconcileAt = DateTimeOffset.UtcNow + ReconcileInterval;
            }

            await Task.Delay(PollInterval, cancellationToken).ConfigureAwait(false);
        }
    }

    internal async Task ProcessIncrementalAsync(
        IReadOnlyList<MacOSExtractedNotification> notifications,
        CancellationToken cancellationToken)
    {
        foreach (var notification in notifications)
        {
            var fingerprint = CreateFingerprint(notification);
            var eventType = _fingerprints.ContainsKey(notification.NotificationId) ? "updated" : "posted";
            if (_fingerprints.TryGetValue(notification.NotificationId, out var previousFingerprint) &&
                string.Equals(previousFingerprint, fingerprint, StringComparison.Ordinal))
            {
                continue;
            }

            _fingerprints[notification.NotificationId] = fingerprint;
            await PublishAsync(eventType, notification, removedAt: null, cancellationToken).ConfigureAwait(false);
        }
    }

    internal async Task ReconcileActiveAsync(
        IReadOnlyList<MacOSExtractedNotification> activeNotifications,
        CancellationToken cancellationToken)
    {
        var activeIds = activeNotifications
            .Select(notification => notification.NotificationId)
            .ToHashSet(StringComparer.Ordinal);

        await ProcessIncrementalAsync(activeNotifications, cancellationToken).ConfigureAwait(false);

        foreach (var removedId in _fingerprints.Keys.Where(id => !activeIds.Contains(id)).ToArray())
        {
            _fingerprints.Remove(removedId);
            await notificationSyncService.HandleLocalNotificationEventAsync(
                "removed",
                new NotificationSyncRecord
                {
                    NotificationId = removedId,
                    SourceDeviceId = identityManager.GetDeviceId()
                },
                DateTimeOffset.UtcNow.ToString("O"),
                cancellationToken).ConfigureAwait(false);
        }
    }

    private Task PublishAsync(
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
