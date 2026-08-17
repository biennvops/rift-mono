using System.Runtime.Versioning;
using Microsoft.Extensions.Logging.Abstractions;
using Rift.Daemon.Core.Interfaces;
using Rift.Daemon.Linux;

namespace Rift.Daemon.Tests.Core;

[SupportedOSPlatform("linux")]
public sealed class LinuxNotificationActionHandlerTests
{
    [Fact]
    public void FreedesktopControl_BuildsExactOwnerAndCloseCalls()
    {
        var owner = LinuxFreedesktopNotificationControl.CreateGetNameOwnerCall();
        Assert.Equal("org.freedesktop.DBus", owner.Destination);
        Assert.Equal("/org/freedesktop/DBus", owner.Path);
        Assert.Equal("org.freedesktop.DBus", owner.Interface);
        Assert.Equal("GetNameOwner", owner.Member);
        Assert.Equal("s", owner.Signature);
        Assert.Equal("org.freedesktop.Notifications", owner.StringArgument);

        var close = LinuxFreedesktopNotificationControl.CreateCloseNotificationCall(":1.42", 7);
        Assert.Equal(":1.42", close.Destination);
        Assert.Equal("/org/freedesktop/Notifications", close.Path);
        Assert.Equal("org.freedesktop.Notifications", close.Interface);
        Assert.Equal("CloseNotification", close.Member);
        Assert.Equal("u", close.Signature);
        Assert.Equal((uint)7, close.UInt32Argument);
    }

    [Fact]
    public void Registry_TracksReplacementClosingRestoreAndRemoval()
    {
        var registry = new LinuxNotificationRegistry();
        var first = CreateTarget(7, ":1.42");
        var replacement = CreateTarget(7, ":1.42") with { NativeNotificationId = 8 };

        registry.Register(first);
        Assert.True(registry.TryGet(first.RiftNotificationId, out var active));
        Assert.Equal(first, active);

        registry.Register(replacement);
        Assert.True(registry.TryGet(first.RiftNotificationId, out active));
        Assert.Equal(replacement, active);

        Assert.True(registry.TryBeginClosing(first.RiftNotificationId, out var closing));
        Assert.Equal(replacement, closing);
        registry.Register(replacement);
        Assert.False(registry.TryGet(first.RiftNotificationId, out _));
        Assert.False(registry.TryBeginClosing(first.RiftNotificationId, out _));

        Assert.True(registry.RestoreActive(replacement));
        Assert.True(registry.TryGet(first.RiftNotificationId, out active));
        Assert.Equal(replacement, active);
        Assert.True(registry.Remove(first.RiftNotificationId));
        Assert.False(registry.TryGet(first.RiftNotificationId, out _));
        Assert.False(registry.Remove(first.RiftNotificationId));
    }

    [Fact]
    public async Task PerformAsync_VerifiesOwnerAndClosesExactTarget()
    {
        var registry = new LinuxNotificationRegistry();
        var target = CreateTarget(7, ":1.42");
        registry.Register(target);
        var control = new RecordingNotificationControl { CurrentOwner = ":1.42" };
        var handler = CreateHandler(registry, control);

        var result = await handler.PerformAsync(
            CreateNotification(target.RiftNotificationId),
            "dismiss",
            CancellationToken.None);

        Assert.True(result.Success);
        Assert.Equal(1, control.OwnerRequestCount);
        var close = Assert.Single(control.CloseRequests);
        Assert.Equal(":1.42", close.NotificationServerOwner);
        Assert.Equal((uint)7, close.NotificationId);
        Assert.False(registry.TryGet(target.RiftNotificationId, out _));
        Assert.False(registry.TryBeginClosing(target.RiftNotificationId, out _));
    }

    [Fact]
    public async Task PerformAsync_DoesNotCloseWhenNotificationServerOwnerChanged()
    {
        var registry = new LinuxNotificationRegistry();
        var target = CreateTarget(7, ":1.42");
        registry.Register(target);
        var control = new RecordingNotificationControl { CurrentOwner = ":1.88" };
        var handler = CreateHandler(registry, control);

        var result = await handler.PerformAsync(
            CreateNotification(target.RiftNotificationId),
            "dismiss",
            CancellationToken.None);

        Assert.False(result.Success);
        Assert.Equal("CapabilityUnavailable", result.FailureReason);
        Assert.Empty(control.CloseRequests);
        Assert.True(registry.TryGet(target.RiftNotificationId, out var restored));
        Assert.Equal(target, restored);
    }

    [Fact]
    public async Task PerformAsync_RestoresTargetAfterNativeFailure()
    {
        var registry = new LinuxNotificationRegistry();
        var target = CreateTarget(7, ":1.42");
        registry.Register(target);
        var control = new RecordingNotificationControl
        {
            CurrentOwner = ":1.42",
            CloseException = new InvalidOperationException("D-Bus failure")
        };
        var handler = CreateHandler(registry, control);

        var result = await handler.PerformAsync(
            CreateNotification(target.RiftNotificationId),
            "dismiss",
            CancellationToken.None);

        Assert.False(result.Success);
        Assert.Equal("CapabilityUnavailable", result.FailureReason);
        Assert.Single(control.CloseRequests);
        Assert.True(registry.TryGet(target.RiftNotificationId, out _));
    }

    [Fact]
    public async Task PerformAsync_ReportsTimeoutAndRestoresTarget()
    {
        var registry = new LinuxNotificationRegistry();
        var target = CreateTarget(7, ":1.42");
        registry.Register(target);
        var control = new RecordingNotificationControl
        {
            CurrentOwner = ":1.42",
            CloseException = new TimeoutException("D-Bus timeout")
        };
        var handler = CreateHandler(registry, control);

        var result = await handler.PerformAsync(
            CreateNotification(target.RiftNotificationId),
            "dismiss",
            CancellationToken.None);

        Assert.False(result.Success);
        Assert.Equal("CapabilityUnavailable", result.FailureReason);
        Assert.Equal("The Linux notification close request timed out.", result.Message);
        Assert.True(registry.TryGet(target.RiftNotificationId, out _));
    }

    [Fact]
    public async Task PerformAsync_AllowsOnlyOneConcurrentClose()
    {
        var registry = new LinuxNotificationRegistry();
        var target = CreateTarget(7, ":1.42");
        registry.Register(target);
        var control = new RecordingNotificationControl
        {
            CurrentOwner = ":1.42",
            BlockClose = true
        };
        var handler = CreateHandler(registry, control);
        var notification = CreateNotification(target.RiftNotificationId);

        var first = handler.PerformAsync(notification, "dismiss", CancellationToken.None);
        await control.CloseEntered.WaitAsync(TimeSpan.FromSeconds(1));
        var second = await handler.PerformAsync(notification, "dismiss", CancellationToken.None);
        control.ReleaseClose();
        var firstResult = await first;

        Assert.True(firstResult.Success);
        Assert.False(second.Success);
        Assert.Equal("CapabilityUnavailable", second.FailureReason);
        Assert.Single(control.CloseRequests);
    }

    [Theory]
    [InlineData("open", "linux")]
    [InlineData("dismiss", "windows")]
    public void CanPerform_RejectsUnsupportedActionOrPlatform(string action, string platform)
    {
        var registry = new LinuxNotificationRegistry();
        var target = CreateTarget(7, ":1.42");
        registry.Register(target);
        var control = new RecordingNotificationControl { CurrentOwner = ":1.42" };
        var handler = CreateHandler(registry, control);

        Assert.False(handler.CanPerform(
            CreateNotification(target.RiftNotificationId, platform),
            action));
    }

    [Fact]
    public void CanPerform_FailsClosedWhenControlIsUnavailable()
    {
        var registry = new LinuxNotificationRegistry();
        var target = CreateTarget(7, ":1.42");
        registry.Register(target);
        var handler = CreateHandler(
            registry,
            new RecordingNotificationControl { IsAvailable = false });

        Assert.False(handler.CanPerform(CreateNotification(target.RiftNotificationId), "dismiss"));
    }

    private static LinuxNotificationActionHandler CreateHandler(
        LinuxNotificationRegistry registry,
        ILinuxNotificationControl control) =>
        new(registry, control, NullLogger<LinuxNotificationActionHandler>.Instance);

    private static LinuxNotificationTarget CreateTarget(uint id, string owner) =>
        new($"linux:{owner}:{id}", owner, id);

    private static NotificationSyncRecord CreateNotification(
        string notificationId,
        string platform = "linux") => new()
        {
            NotificationId = notificationId,
            SourceDeviceId = "rift-local",
            SourcePlatform = platform,
            PackageName = "org.example.Chat",
            AppName = "Example Chat",
            PostedAt = "2026-08-08T12:00:00Z",
            IsDismissible = true
        };

    private sealed class RecordingNotificationControl : ILinuxNotificationControl
    {
        private readonly TaskCompletionSource _closeEntered =
            new(TaskCreationOptions.RunContinuationsAsynchronously);
        private readonly TaskCompletionSource _releaseClose =
            new(TaskCreationOptions.RunContinuationsAsynchronously);

        public bool IsAvailable { get; set; } = true;
        public string CurrentOwner { get; set; } = ":1.42";
        public Exception? CloseException { get; init; }
        public bool BlockClose { get; init; }
        public int OwnerRequestCount { get; private set; }
        public List<(string NotificationServerOwner, uint NotificationId)> CloseRequests { get; } = [];
        public Task CloseEntered => _closeEntered.Task;

        public Task<string> GetNotificationServerOwnerAsync(CancellationToken cancellationToken)
        {
            OwnerRequestCount++;
            return Task.FromResult(CurrentOwner);
        }

        public async Task CloseNotificationAsync(
            string notificationServerOwner,
            uint notificationId,
            CancellationToken cancellationToken)
        {
            CloseRequests.Add((notificationServerOwner, notificationId));
            _closeEntered.TrySetResult();
            if (BlockClose)
            {
                await _releaseClose.Task.WaitAsync(cancellationToken);
            }
            if (CloseException is not null)
            {
                throw CloseException;
            }
        }

        public void ReleaseClose() => _releaseClose.TrySetResult();
    }
}
