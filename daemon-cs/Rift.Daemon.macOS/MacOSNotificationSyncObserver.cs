using Rift.Daemon.Core.Interfaces;

namespace Rift.Daemon.macOS;

internal sealed class MacOSNotificationSyncObserver(
    IMacOSNotificationExtractorClient extractorClient,
    INotificationSyncService notificationSyncService,
    IIdentityManager identityManager,
    ILogger<MacOSNotificationSyncObserver> logger) : BackgroundService
{
    private const int ExtractorPageSize = 64;
    private const int MaximumCapabilityUpgradesPerPoll = 64;
    private static readonly TimeSpan PollInterval = TimeSpan.FromSeconds(2);
    private static readonly TimeSpan RetryInterval = TimeSpan.FromSeconds(30);

    private readonly Dictionary<string, string> _fingerprints = new(StringComparer.Ordinal);
    private readonly Dictionary<string, MacOSExtractedNotification> _trackedNotifications = new(StringComparer.Ordinal);
    private readonly SortedSet<TrackedNotificationKey> _nonDismissibleNotifications = new(TrackedNotificationKeyComparer.Instance);
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
            await PollOnceAsync(cancellationToken).ConfigureAwait(false);
            await Task.Delay(PollInterval, cancellationToken).ConfigureAwait(false);
        }
    }

    internal async Task PollOnceAsync(CancellationToken cancellationToken)
    {
        await RefreshActionCapabilitiesAsync(cancellationToken).ConfigureAwait(false);
        var scan = await extractorClient.ScanNotificationChangesAsync(_cursor, cancellationToken).ConfigureAwait(false);
        await ProcessIncrementalAsync(scan.Notifications, cancellationToken).ConfigureAwait(false);
        _cursor = Math.Max(_cursor, scan.Cursor);
        if (scan.Notifications.Count > 0 || scan.SkippedRecords > 0)
        {
            logger.LogInformation(
                "macOS notification scan returned {NotificationCount} records and skipped {SkippedCount} at cursor {Cursor}.",
                scan.Notifications.Count,
                scan.SkippedRecords,
                _cursor);
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

            var actionableNotification = await ResolveActionCapabilitiesAsync(notification, cancellationToken)
                .ConfigureAwait(false);
            var fingerprint = CreateFingerprint(actionableNotification);
            var eventType = _fingerprints.ContainsKey(actionableNotification.NotificationId) ? "updated" : "posted";
            if (_fingerprints.TryGetValue(actionableNotification.NotificationId, out var previousFingerprint) &&
                string.Equals(previousFingerprint, fingerprint, StringComparison.Ordinal))
            {
                TrackNotification(actionableNotification);
                continue;
            }

            var result = await PublishAsync(eventType, actionableNotification, removedAt: null, cancellationToken).ConfigureAwait(false);
            _fingerprints[actionableNotification.NotificationId] = fingerprint;
            TrackNotification(actionableNotification);
            logger.LogInformation(
                "macOS notification {EventType} processed (suppressed={Suppressed}, broadcastPeers={BroadcastPeerCount}).",
                eventType,
                result.Suppressed,
                result.BroadcastTo.Count);
        }
    }

    internal async Task RefreshActionCapabilitiesAsync(CancellationToken cancellationToken)
    {
        var currentlyDismissible = _trackedNotifications.Values
            .Where(notification => notification.IsDismissible)
            .ToArray();
        var upgradeCandidates = _nonDismissibleNotifications
            .Reverse()
            .Take(MaximumCapabilityUpgradesPerPoll)
            .Select(key => _trackedNotifications[key.NotificationId])
            .ToArray();

        foreach (var notification in currentlyDismissible.Concat(upgradeCandidates))
        {
            var updated = await ResolveActionCapabilitiesAsync(notification, cancellationToken)
                .ConfigureAwait(false);
            if (updated.IsDismissible == notification.IsDismissible &&
                updated.IsOpenable == notification.IsOpenable)
            {
                continue;
            }

            await PublishAsync("updated", updated, removedAt: null, cancellationToken).ConfigureAwait(false);
            TrackNotification(updated);
            _fingerprints[updated.NotificationId] = CreateFingerprint(updated);
            logger.LogInformation(
                "macOS notification action capability changed (dismissible={IsDismissible}).",
                updated.IsDismissible);
        }
    }

    private void TrackNotification(MacOSExtractedNotification notification)
    {
        if (_trackedNotifications.TryGetValue(notification.NotificationId, out var previous) &&
            !previous.IsDismissible)
        {
            _nonDismissibleNotifications.Remove(CreateTrackingKey(previous));
        }

        _trackedNotifications[notification.NotificationId] = notification;
        if (notification.IsDismissible)
        {
            return;
        }

        _nonDismissibleNotifications.Add(CreateTrackingKey(notification));
        while (_nonDismissibleNotifications.Count > MaximumCapabilityUpgradesPerPoll)
        {
            var oldest = _nonDismissibleNotifications.Min;
            _nonDismissibleNotifications.Remove(oldest);

            if (_trackedNotifications.TryGetValue(oldest.NotificationId, out var tracked) &&
                !tracked.IsDismissible &&
                string.Equals(tracked.PostedAt, oldest.PostedAt, StringComparison.Ordinal))
            {
                _trackedNotifications.Remove(oldest.NotificationId);
            }
        }
    }

    private static TrackedNotificationKey CreateTrackingKey(MacOSExtractedNotification notification) =>
        new(notification.NotificationId, notification.PostedAt);

    private async Task<MacOSExtractedNotification> ResolveActionCapabilitiesAsync(
        MacOSExtractedNotification notification,
        CancellationToken cancellationToken)
    {
        try
        {
            var capabilities = await extractorClient.GetNotificationActionCapabilitiesAsync(
                    notification.NotificationId,
                    notification.PackageName,
                    cancellationToken)
                .ConfigureAwait(false);
            return CloneNotification(
                notification,
                isDismissible: capabilities.CanDismiss,
                isOpenable: false);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (MacOSExtractorException ex)
        {
            logger.LogDebug(
                "macOS notification action capability unavailable ({Code}): {Message}",
                ex.Code,
                ex.Message);
            return CloneNotification(notification, isDismissible: false, isOpenable: false);
        }
    }

    private static MacOSExtractedNotification CloneNotification(
        MacOSExtractedNotification notification,
        bool isDismissible,
        bool isOpenable) => new()
        {
            NotificationId = notification.NotificationId,
            PackageName = notification.PackageName,
            AppName = notification.AppName,
            Title = notification.Title,
            BodyPreview = notification.BodyPreview,
            PostedAt = notification.PostedAt,
            IsDismissible = isDismissible,
            IsOpenable = isOpenable
        };

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
                IsDismissible = notification.IsDismissible,
                IsOpenable = notification.IsOpenable
            },
            removedAt,
            cancellationToken);

    private static bool ShouldIgnore(string packageName) =>
        string.Equals(packageName, "dev.rift.app", StringComparison.OrdinalIgnoreCase) ||
        packageName.StartsWith("com.rift.", StringComparison.OrdinalIgnoreCase);

    private static string CreateFingerprint(MacOSExtractedNotification notification) => string.Join(
        '\n',
        notification.PackageName,
        notification.AppName,
        notification.Title ?? string.Empty,
        notification.BodyPreview ?? string.Empty,
        notification.PostedAt,
        notification.IsDismissible ? "1" : "0",
        notification.IsOpenable ? "1" : "0");

    private static string GetStatusMessage(string state) => state switch
    {
        "databaseNotFound" => "The macOS Notification Center database was not found.",
        "fullDiskAccessRequired" => "Full Disk Access is required for Rift Notification Extractor.",
        "unsupportedSchema" => "The macOS Notification Center schema is not supported.",
        _ => "Rift Notification Extractor is not ready."
    };

    private readonly record struct TrackedNotificationKey(string NotificationId, string PostedAt);

    private sealed class TrackedNotificationKeyComparer : IComparer<TrackedNotificationKey>
    {
        internal static TrackedNotificationKeyComparer Instance { get; } = new();

        public int Compare(TrackedNotificationKey left, TrackedNotificationKey right)
        {
            var postedAtComparison = StringComparer.Ordinal.Compare(left.PostedAt, right.PostedAt);
            return postedAtComparison != 0
                ? postedAtComparison
                : StringComparer.Ordinal.Compare(left.NotificationId, right.NotificationId);
        }
    }
}
