using System.Runtime.Versioning;
using Microsoft.Extensions.Logging.Abstractions;
using Rift.Daemon.Core.Interfaces;
using Rift.Daemon.macOS;

namespace Rift.Daemon.Tests.Core;

[SupportedOSPlatform("macos")]
public sealed class MacOSNotificationActionHandlerTests
{
    [Fact]
    public void CanPerform_RequiresAdvertisedMacOSDismiss()
    {
        var handler = CreateHandler(new StubExtractorClient());

        Assert.True(handler.CanPerform(CreateNotification(), "dismiss"));
        Assert.False(handler.CanPerform(CreateNotification(isDismissible: false), "dismiss"));
        Assert.False(handler.CanPerform(CreateNotification(sourcePlatform: "linux"), "dismiss"));
        Assert.False(handler.CanPerform(CreateNotification(), "open"));
    }

    [Fact]
    public async Task PerformAsync_RevalidatesAndReturnsVerifiedSuccess()
    {
        var extractor = new StubExtractorClient
        {
            Capabilities = new MacOSNotificationActionCapabilities { CanDismiss = true },
            DismissResult = new MacOSNotificationDismissResult
            {
                Backend = "accessibility",
                Success = true,
                Reason = "verified"
            }
        };
        var handler = CreateHandler(extractor);

        var result = await handler.PerformAsync(
            CreateNotification(),
            "dismiss",
            CancellationToken.None);

        Assert.True(result.Success);
        Assert.Equal(1, extractor.CapabilityCalls);
        Assert.Equal(1, extractor.DismissCalls);
        Assert.Equal("notification-1", extractor.LastNotificationId);
        Assert.Equal("com.example.source", extractor.LastPackageName);
    }

    [Fact]
    public async Task PerformAsync_FailsClosedWhenExactCapabilityDisappears()
    {
        var extractor = new StubExtractorClient
        {
            Capabilities = new MacOSNotificationActionCapabilities
            {
                CanDismiss = false,
                Reason = "exactIdentityUnavailable"
            }
        };
        var handler = CreateHandler(extractor);

        var result = await handler.PerformAsync(
            CreateNotification(),
            "dismiss",
            CancellationToken.None);

        Assert.False(result.Success);
        Assert.Equal("CapabilityUnavailable", result.FailureReason);
        Assert.Equal(1, extractor.CapabilityCalls);
        Assert.Equal(0, extractor.DismissCalls);
    }

    private static MacOSNotificationActionHandler CreateHandler(IMacOSNotificationExtractorClient extractor) =>
        new(extractor, NullLogger<MacOSNotificationActionHandler>.Instance);

    private static NotificationSyncRecord CreateNotification(
        bool isDismissible = true,
        string sourcePlatform = "macos") => new()
        {
            NotificationId = "notification-1",
            SourceDeviceId = "rift-local",
            SourcePlatform = sourcePlatform,
            PackageName = "com.example.source",
            AppName = "Example",
            PostedAt = "2026-08-17T00:00:00Z",
            IsDismissible = isDismissible,
            IsOpenable = false
        };

    private sealed class StubExtractorClient : IMacOSNotificationExtractorClient
    {
        public MacOSNotificationActionCapabilities Capabilities { get; init; } = new();
        public MacOSNotificationDismissResult DismissResult { get; init; } = new();
        public int CapabilityCalls { get; private set; }
        public int DismissCalls { get; private set; }
        public string? LastNotificationId { get; private set; }
        public string? LastPackageName { get; private set; }

        public Task<MacOSNotificationActionCapabilities> GetNotificationActionCapabilitiesAsync(
            string notificationId,
            string packageName,
            CancellationToken cancellationToken)
        {
            CapabilityCalls++;
            LastNotificationId = notificationId;
            LastPackageName = packageName;
            return Task.FromResult(Capabilities);
        }

        public Task<MacOSNotificationDismissResult> DismissNotificationAsync(
            string notificationId,
            string packageName,
            CancellationToken cancellationToken)
        {
            DismissCalls++;
            LastNotificationId = notificationId;
            LastPackageName = packageName;
            return Task.FromResult(DismissResult);
        }

        public Task<MacOSNotificationActionBackendStatus> GetNotificationActionBackendStatusAsync(
            CancellationToken cancellationToken) =>
            throw new NotSupportedException();

        public Task<MacOSExtractorStatus> GetStatusAsync(CancellationToken cancellationToken) =>
            throw new NotSupportedException();

        public Task<MacOSExtractorScanResult> ScanNotificationChangesAsync(
            long cursor,
            CancellationToken cancellationToken) =>
            throw new NotSupportedException();

        public Task<MacOSExtractorScanResult> RescanActiveNotificationsAsync(
            CancellationToken cancellationToken) =>
            throw new NotSupportedException();
    }
}
