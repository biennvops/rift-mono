using System.Runtime.Versioning;
using System.Security.Cryptography.X509Certificates;
using Microsoft.Extensions.Logging.Abstractions;
using Rift.Daemon.Core.Interfaces;
using Rift.Daemon.macOS;

namespace Rift.Daemon.Tests.Core;

[SupportedOSPlatform("macos")]
public sealed class MacOSNotificationSyncObserverTests
{
    [Fact]
    public async Task ProcessIncrementalAsync_PostsUpdatesAndDeduplicatesNotifications()
    {
        var syncService = new RecordingNotificationSyncService();
        var observer = CreateObserver(syncService);
        var notification = CreateNotification("notification-1", "First title");

        await observer.ProcessIncrementalAsync([notification], CancellationToken.None);
        await observer.ProcessIncrementalAsync([notification], CancellationToken.None);
        await observer.ProcessIncrementalAsync([CreateNotification("notification-1", "Updated title")], CancellationToken.None);

        Assert.Equal(["posted", "updated"], syncService.Events.Select(evt => evt.EventType));
        Assert.All(syncService.Events, evt =>
        {
            Assert.Equal("rift-local", evt.Notification.SourceDeviceId);
            Assert.Equal("macos", evt.Notification.SourcePlatform);
            Assert.False(evt.Notification.IsDismissible);
            Assert.False(evt.Notification.IsOpenable);
        });
    }

    [Fact]
    public async Task ReconcileActiveAsync_RemovesNotificationsMissingFromDeliveredSet()
    {
        var syncService = new RecordingNotificationSyncService();
        var observer = CreateObserver(syncService);
        await observer.ProcessIncrementalAsync(
            [CreateNotification("notification-1", "First")],
            CancellationToken.None);
        syncService.Events.Clear();

        await observer.ReconcileActiveAsync(
            [CreateNotification("notification-2", "Second")],
            CancellationToken.None);

        Assert.Equal(["posted", "removed"], syncService.Events.Select(evt => evt.EventType));
        var removal = syncService.Events[1];
        Assert.Equal("notification-1", removal.Notification.NotificationId);
        Assert.NotNull(removal.RemovedAt);
    }

    private static MacOSNotificationSyncObserver CreateObserver(RecordingNotificationSyncService syncService) =>
        new(
            new StubExtractorClient(),
            syncService,
            new StubIdentityManager(),
            NullLogger<MacOSNotificationSyncObserver>.Instance);

    private static MacOSExtractedNotification CreateNotification(string id, string title) => new()
    {
        NotificationId = id,
        PackageName = "com.example.app",
        AppName = "Example",
        Title = title,
        BodyPreview = "Preview",
        PostedAt = "2026-07-20T00:00:00.0000000+00:00",
        IsDismissible = true,
        IsOpenable = true
    };

    private sealed class StubExtractorClient : IMacOSNotificationExtractorClient
    {
        public Task<MacOSExtractorStatus> GetStatusAsync(CancellationToken cancellationToken) => throw new NotSupportedException();
        public Task<MacOSExtractorScanResult> ScanNotificationChangesAsync(long cursor, CancellationToken cancellationToken) => throw new NotSupportedException();
        public Task<MacOSExtractorScanResult> RescanActiveNotificationsAsync(CancellationToken cancellationToken) => throw new NotSupportedException();
    }

    private sealed class StubIdentityManager : IIdentityManager
    {
        public void EnsureIdentityInitialized() { }
        public string GetDeviceId() => "rift-local";
        public byte[] GetEd25519PublicKey() => throw new NotSupportedException();
        public X509Certificate2 GetTlsCertificate() => throw new NotSupportedException();
        public byte[] SignEd25519(byte[] data) => throw new NotSupportedException();
        public string GetFingerprint() => throw new NotSupportedException();
        public string GetDisplayName() => throw new NotSupportedException();
        public bool VerifyEd25519(byte[] publicKey, byte[] data, byte[] signature) => throw new NotSupportedException();
    }

    private sealed class RecordingNotificationSyncService : INotificationSyncService
    {
        public List<RecordedEvent> Events { get; } = [];

        public Task<NotifyLocalNotificationEventResult> HandleLocalNotificationEventAsync(
            string eventType,
            NotificationSyncRecord notification,
            string? removedAt,
            CancellationToken cancellationToken)
        {
            Events.Add(new RecordedEvent(eventType, notification, removedAt));
            return Task.FromResult(new NotifyLocalNotificationEventResult
            {
                NotificationId = notification.NotificationId
            });
        }

        public Task<ListNotificationsResult> ListNotificationsAsync(CancellationToken cancellationToken) => throw new NotSupportedException();
        public Task<PerformNotificationActionResult> PerformNotificationActionAsync(string notificationId, string action, CancellationToken cancellationToken) => throw new NotSupportedException();
        public Task<NotificationSyncPolicy> UpdateNotificationSyncPolicyAsync(bool enabled, IReadOnlyList<string> blacklistedPackages, CancellationToken cancellationToken) => throw new NotSupportedException();
        public Task HandleNotificationPostedAsync(NotificationSyncRecord notification, CancellationToken cancellationToken) => throw new NotSupportedException();
        public Task HandleNotificationUpdatedAsync(NotificationSyncRecord notification, CancellationToken cancellationToken) => throw new NotSupportedException();
        public Task HandleNotificationRemovedAsync(NotificationRemovedRecord notification, CancellationToken cancellationToken) => throw new NotSupportedException();
        public Task HandleNotificationActionResultAsync(NotificationActionResultRecord result, CancellationToken cancellationToken) => throw new NotSupportedException();
    }

    private sealed record RecordedEvent(
        string EventType,
        NotificationSyncRecord Notification,
        string? RemovedAt);
}
