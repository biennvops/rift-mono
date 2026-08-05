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
        var scriptPath = await CreateSuccessfulAdapterScriptAsync();
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

    [Fact]
    public async Task HandleActionAsync_ConvertsSeekPositionToMicroseconds()
    {
        var argsPath = Path.Combine(_tempDirectory, "adapter-args.txt");
        var scriptPath = await CreateArgumentCapturingAdapterScriptAsync(argsPath);
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
                Action = "seek",
                PositionMs = 12_345,
            },
            CancellationToken.None);

        Assert.True(result.Success);
        var args = await File.ReadAllLinesAsync(argsPath);
        Assert.Equal([frameworkPath, "seek", "12345000"], args);
    }

    [Theory]
    [InlineData(12.5, 7.0, 12500)]
    [InlineData(null, 7.0, 7000)]
    public void GetPositionMs_PrefersContinuouslyAdvancingElapsedTime(
        double? elapsedTimeNow,
        double? elapsedTime,
        long expectedPositionMs)
    {
        Assert.Equal(expectedPositionMs, MacOSMediaPlaybackService.GetPositionMs(elapsedTimeNow, elapsedTime));
    }

    [Fact]
    public void CreateGetCommand_RequestsAdvancingElapsedTime()
    {
        Assert.Equal(["get", "--now"], MacOSMediaPlaybackService.CreateGetCommand());
    }

    [Fact]
    public void CreatePlaybackId_IsStableForNowPlayingApplication()
    {
        Assert.Equal(
            "com.example.browser:now-playing",
            MacOSMediaPlaybackService.CreatePlaybackId("com.example.browser"));
    }

    [Theory]
    [InlineData("com.example.appFlutter", null)]
    [InlineData("com.rift.desktop", null)]
    [InlineData("com.example.other", "rift.remote:rift-peer:playback-1")]
    public void IsRiftRemotePlayback_RecognizesMirroredNowPlayingMetadata(
        string? bundleIdentifier,
        string? contentItemIdentifier)
    {
        Assert.True(MacOSMediaPlaybackService.IsRiftRemotePlayback(bundleIdentifier, contentItemIdentifier));
    }

    [Fact]
    public void IsRiftRemotePlayback_AllowsOtherApplications()
    {
        Assert.False(MacOSMediaPlaybackService.IsRiftRemotePlayback(
            "com.apple.Music",
            "music:track-1"));
    }

    private async Task<string> CreateSuccessfulAdapterScriptAsync()
    {
        var scriptPath = Path.Combine(_tempDirectory, "mediaremote-adapter.pl");
        await File.WriteAllTextAsync(
            scriptPath,
            "#!/usr/bin/perl\nuse strict;\nuse warnings;\nexit 0;\n");
        SetExecutable(scriptPath);
        return scriptPath;
    }

    private async Task<string> CreateArgumentCapturingAdapterScriptAsync(string argsPath)
    {
        var scriptPath = Path.Combine(_tempDirectory, "mediaremote-adapter.pl");
        await File.WriteAllTextAsync(
            scriptPath,
            $"#!/usr/bin/perl\nuse strict;\nuse warnings;\nmy $path = q{{{argsPath}}};\nopen(my $fh, '>', $path) or die $!;\nforeach my $arg (@ARGV) {{ print $fh $arg . \"\\n\"; }}\nclose($fh);\nexit 0;\n");
        SetExecutable(scriptPath);
        return scriptPath;
    }

    private static void SetExecutable(string scriptPath)
    {
        File.SetUnixFileMode(
            scriptPath,
            UnixFileMode.UserRead |
                UnixFileMode.UserWrite |
                UnixFileMode.UserExecute |
                UnixFileMode.GroupRead |
                UnixFileMode.GroupExecute |
                UnixFileMode.OtherRead |
                UnixFileMode.OtherExecute);
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
