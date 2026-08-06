using System.Runtime.CompilerServices;
using System.Runtime.Versioning;
using System.Security.Cryptography.X509Certificates;
using Microsoft.Extensions.Logging.Abstractions;
using Rift.Daemon.Core.Interfaces;
using Rift.Daemon.Linux;

namespace Rift.Daemon.Tests.Core;

[SupportedOSPlatform("linux")]
public sealed class LinuxNotificationSyncObserverTests
{
    [Fact]
    public async Task ProcessEventAsync_PostsUpdatesAndRemovesNotifications()
    {
        var syncService = new RecordingNotificationSyncService();
        var observer = CreateObserver(syncService);

        await observer.ProcessEventAsync(CreateCall(serial: 10), CancellationToken.None);
        await observer.ProcessEventAsync(CreateReply(replySerial: 10), CancellationToken.None);
        await observer.ProcessEventAsync(CreateCall(serial: 11, replacesId: 42, summary: "Updated"), CancellationToken.None);
        await observer.ProcessEventAsync(CreateReply(replySerial: 11), CancellationToken.None);
        await observer.ProcessEventAsync(new LinuxNotificationClosed(":1.5", 42), CancellationToken.None);

        Assert.Equal(["posted", "updated", "removed"], syncService.Events.Select(evt => evt.EventType));
        Assert.Equal("linux::1.5:42", syncService.Events[0].Notification.NotificationId);
        Assert.Equal("linux", syncService.Events[0].Notification.SourcePlatform);
        Assert.Equal("org.example.Chat", syncService.Events[0].Notification.PackageName);
        Assert.Equal("Example Chat", syncService.Events[0].Notification.AppName);
        Assert.False(syncService.Events[0].Notification.IsDismissible);
        Assert.False(syncService.Events[0].Notification.IsOpenable);
        Assert.Equal("Updated", syncService.Events[1].Notification.Title);
        Assert.NotNull(syncService.Events[2].RemovedAt);
    }

    [Fact]
    public async Task ProcessEventAsync_IgnoresRiftOwnedNotifications()
    {
        var syncService = new RecordingNotificationSyncService();
        var observer = CreateObserver(syncService);

        await observer.ProcessEventAsync(
            CreateCall(serial: 10, desktopEntry: "dev.rift.Rift"),
            CancellationToken.None);
        await observer.ProcessEventAsync(CreateReply(replySerial: 10), CancellationToken.None);

        Assert.Empty(syncService.Events);
    }

    [Fact]
    public async Task ProcessEventAsync_IgnoresUnknownRepliesAndClosures()
    {
        var syncService = new RecordingNotificationSyncService();
        var observer = CreateObserver(syncService);

        await observer.ProcessEventAsync(CreateReply(replySerial: 99), CancellationToken.None);
        await observer.ProcessEventAsync(new LinuxNotificationClosed(":1.5", 99), CancellationToken.None);

        Assert.Empty(syncService.Events);
    }

    [Fact]
    public async Task ProcessEventAsync_BoundsNotificationPreviews()
    {
        var syncService = new RecordingNotificationSyncService();
        var observer = CreateObserver(syncService);

        await observer.ProcessEventAsync(
            CreateCall(serial: 10, summary: new string('T', 300), body: new string('B', 1200)),
            CancellationToken.None);
        await observer.ProcessEventAsync(CreateReply(replySerial: 10), CancellationToken.None);

        var notification = Assert.Single(syncService.Events).Notification;
        Assert.Equal(256, notification.Title!.Length);
        Assert.Equal(1024, notification.BodyPreview!.Length);
    }

    [Fact]
    public async Task ProcessEventAsync_FallsBackToApplicationNameForPackageIdentity()
    {
        var syncService = new RecordingNotificationSyncService();
        var observer = CreateObserver(syncService);

        await observer.ProcessEventAsync(
            CreateCall(serial: 10, desktopEntry: null),
            CancellationToken.None);
        await observer.ProcessEventAsync(CreateReply(replySerial: 10), CancellationToken.None);

        Assert.Equal("Example Chat", Assert.Single(syncService.Events).Notification.PackageName);
    }

    private static LinuxNotificationSyncObserver CreateObserver(RecordingNotificationSyncService syncService) =>
        new(
            new EmptyNotificationMonitor(),
            syncService,
            new StubIdentityManager(),
            NullLogger<LinuxNotificationSyncObserver>.Instance);

    private static LinuxNotificationPostedCall CreateCall(
        uint serial,
        uint replacesId = 0,
        string summary = "Message",
        string body = "Hello",
        string? desktopEntry = "org.example.Chat") =>
        new(
            Sender: ":1.20",
            Serial: serial,
            AppName: "Example Chat",
            ReplacesId: replacesId,
            Summary: summary,
            Body: body,
            DesktopEntry: desktopEntry,
            ReceivedAt: new DateTimeOffset(2026, 8, 8, 12, 0, 0, TimeSpan.Zero));

    private static LinuxNotificationPostedReply CreateReply(uint replySerial) =>
        new(
            Sender: ":1.5",
            Destination: ":1.20",
            ReplySerial: replySerial,
            NotificationId: 42);

    private sealed class EmptyNotificationMonitor : ILinuxNotificationMonitor
    {
        public async IAsyncEnumerable<LinuxNotificationBusEvent> ObserveAsync(
            [EnumeratorCancellation] CancellationToken cancellationToken)
        {
            await Task.CompletedTask;
            yield break;
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
