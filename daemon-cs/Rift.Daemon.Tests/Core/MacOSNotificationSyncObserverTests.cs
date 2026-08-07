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
    public async Task PollOnceAsync_RetriesPageAndNotificationWhenPublicationFails()
    {
        var syncService = new RecordingNotificationSyncService { FailuresRemaining = 1 };
        var extractorClient = new StubExtractorClient
        {
            ScanResult = new MacOSExtractorScanResult
            {
                Cursor = 42,
                Notifications = [CreateNotification("notification-1", "First title")]
            }
        };
        var observer = CreateObserver(syncService, extractorClient);

        await Assert.ThrowsAsync<InvalidOperationException>(() => observer.PollOnceAsync(CancellationToken.None));
        await observer.PollOnceAsync(CancellationToken.None);
        await observer.PollOnceAsync(CancellationToken.None);

        Assert.Equal([0L, 0L, 42L], extractorClient.ScanCursors);
        Assert.Equal(2, syncService.HandleCalls);
        Assert.Single(syncService.Events);
    }

    [Fact]
    public async Task BootstrapAsync_AdvancesCursorWithoutReplayingHistoricalNotifications()
    {
        var syncService = new RecordingNotificationSyncService();
        var extractorClient = new StubExtractorClient
        {
            ScanResult = new MacOSExtractorScanResult
            {
                Cursor = 42,
                Notifications = [CreateNotification("historical-game-mode", "Game Mode: On")]
            }
        };
        var observer = CreateObserver(syncService, extractorClient);

        await observer.BootstrapAsync(CancellationToken.None);
        await observer.BootstrapAsync(CancellationToken.None);

        Assert.Empty(syncService.Events);
        Assert.Equal(1, extractorClient.ScanCalls);
        Assert.Equal(0, extractorClient.RescanCalls);
    }

    [Theory]
    [InlineData("dev.rift.app")]
    [InlineData("com.rift.app")]
    [InlineData("com.rift.notification-extractor")]
    public async Task ProcessIncrementalAsync_IgnoresRiftOwnedNotifications(string packageName)
    {
        var syncService = new RecordingNotificationSyncService();
        var observer = CreateObserver(syncService);

        await observer.ProcessIncrementalAsync(
            [CreateNotification("rift-notification", "Mirrored notification", packageName)],
            CancellationToken.None);

        Assert.Empty(syncService.Events);
    }

    private static MacOSNotificationSyncObserver CreateObserver(
        RecordingNotificationSyncService syncService,
        IMacOSNotificationExtractorClient? extractorClient = null) =>
        new(
            extractorClient ?? new StubExtractorClient(),
            syncService,
            new StubIdentityManager(),
            NullLogger<MacOSNotificationSyncObserver>.Instance);

    private static MacOSExtractedNotification CreateNotification(
        string id,
        string title,
        string packageName = "com.example.app") => new()
        {
            NotificationId = id,
            PackageName = packageName,
            AppName = "Example",
            Title = title,
            BodyPreview = "Preview",
            PostedAt = "2026-07-20T00:00:00.0000000+00:00",
            IsDismissible = true,
            IsOpenable = true
        };

    private sealed class StubExtractorClient : IMacOSNotificationExtractorClient
    {
        public MacOSExtractorScanResult ScanResult { get; init; } = new();
        public int ScanCalls { get; private set; }
        public int RescanCalls { get; private set; }
        public List<long> ScanCursors { get; } = [];

        public Task<MacOSExtractorStatus> GetStatusAsync(CancellationToken cancellationToken) =>
            Task.FromResult(new MacOSExtractorStatus
            {
                DatabaseFound = true,
                DatabaseReadable = true,
                SchemaSupported = true,
                State = "ready"
            });

        public Task<MacOSExtractorScanResult> ScanNotificationChangesAsync(long cursor, CancellationToken cancellationToken)
        {
            ScanCalls++;
            ScanCursors.Add(cursor);
            return Task.FromResult(ScanResult);
        }

        public Task<MacOSExtractorScanResult> RescanActiveNotificationsAsync(CancellationToken cancellationToken)
        {
            RescanCalls++;
            throw new NotSupportedException();
        }
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
        public int FailuresRemaining { get; set; }
        public int HandleCalls { get; private set; }

        public Task<NotifyLocalNotificationEventResult> HandleLocalNotificationEventAsync(
            string eventType,
            NotificationSyncRecord notification,
            string? removedAt,
            CancellationToken cancellationToken)
        {
            HandleCalls++;
            if (FailuresRemaining > 0)
            {
                FailuresRemaining--;
                throw new InvalidOperationException("Publication failed.");
            }

            Events.Add(new RecordedEvent(eventType, notification, removedAt));
            return Task.FromResult(new NotifyLocalNotificationEventResult
            {
                NotificationId = notification.NotificationId
            });
        }

        public Task<ListNotificationsResult> ListNotificationsAsync(CancellationToken cancellationToken) => throw new NotSupportedException();
        public Task<PerformNotificationActionResult> PerformNotificationActionAsync(string notificationId, string action, CancellationToken cancellationToken) => throw new NotSupportedException();
        public Task<NotificationSyncPolicy> UpdateNotificationSyncPolicyAsync(bool enabled, string mode, IReadOnlyList<string> packageNames, CancellationToken cancellationToken) => throw new NotSupportedException();
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
