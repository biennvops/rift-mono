using System.Runtime.Versioning;
using Microsoft.Extensions.Logging.Abstractions;
using Rift.Daemon.Core.Interfaces;
using Rift.Daemon.macOS;

namespace Rift.Daemon.Tests.Core;

[SupportedOSPlatform("macos")]
public sealed class MacOSMediaPlaybackServiceTests : IDisposable
{
    private readonly string? _originalScriptPath = Environment.GetEnvironmentVariable("RIFT_MEDIAREMOTE_SCRIPT");
    private readonly string? _originalFrameworkPath = Environment.GetEnvironmentVariable("RIFT_MEDIAREMOTE_FRAMEWORK");
    private readonly string _tempDirectory;

    public MacOSMediaPlaybackServiceTests()
    {
        _tempDirectory = Directory.CreateTempSubdirectory("rift-macos-media-playback").FullName;
    }

    [Theory]
    [InlineData("next")]
    [InlineData("previous")]
    public async Task HandleActionAsync_AcceptsNormalizedTransportActions(string action)
    {
        var scriptPath = Path.Combine(_tempDirectory, "mediaremote-adapter.pl");
        await File.WriteAllTextAsync(
            scriptPath,
            "#!/usr/bin/perl\nuse strict;\nuse warnings;\nexit 0;\n");
        File.SetUnixFileMode(
            scriptPath,
            UnixFileMode.UserRead |
                UnixFileMode.UserWrite |
                UnixFileMode.UserExecute |
                UnixFileMode.GroupRead |
                UnixFileMode.GroupExecute |
                UnixFileMode.OtherRead |
                UnixFileMode.OtherExecute);

        var frameworkPath = Path.Combine(_tempDirectory, "MediaRemoteAdapter.framework");
        Directory.CreateDirectory(frameworkPath);

        Environment.SetEnvironmentVariable("RIFT_MEDIAREMOTE_SCRIPT", scriptPath);
        Environment.SetEnvironmentVariable("RIFT_MEDIAREMOTE_FRAMEWORK", frameworkPath);

        var service = new MacOSMediaPlaybackService(new StubServiceProvider(), NullLogger<MacOSMediaPlaybackService>.Instance);

        var result = await service.HandleActionAsync(
            new PendingIncomingMediaPlaybackAction
            {
                RequestId = Guid.NewGuid().ToString("D"),
                SourceDeviceId = "rift-source",
                RequestingDeviceId = "rift-requester",
                PlaybackId = "playback-1",
                Action = action,
                PositionMs = null,
            },
            CancellationToken.None);

        Assert.True(result.Success);
        Assert.Null(result.FailureReason);
    }

    public void Dispose()
    {
        Environment.SetEnvironmentVariable("RIFT_MEDIAREMOTE_SCRIPT", _originalScriptPath);
        Environment.SetEnvironmentVariable("RIFT_MEDIAREMOTE_FRAMEWORK", _originalFrameworkPath);
        if (Directory.Exists(_tempDirectory))
        {
            Directory.Delete(_tempDirectory, recursive: true);
        }
    }

    private sealed class StubServiceProvider : IServiceProvider
    {
        public object? GetService(Type serviceType) => null;
    }
}
