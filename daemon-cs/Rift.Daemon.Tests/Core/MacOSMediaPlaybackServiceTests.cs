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
                OperationId = Guid.NewGuid().ToString("D"),
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
                OperationId = Guid.NewGuid().ToString("D"),
                SourceDeviceId = "rift-source",
                RequestingDeviceId = "rift-requester",
                PlaybackId = "playback-1",
                Action = "seek",
                PositionMs = 12_345,
            },
            CancellationToken.None);

        Assert.True(result.Success);
        var args = await File.ReadAllLinesAsync(argsPath);
        Assert.Equal([frameworkPath, "seek", "12345000"], args.Take(3));
    }

    [Fact]
    public async Task HandleActionAsync_SerializesAdapterCommands()
    {
        var firstStarted = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var releaseFirst = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var secondStarted = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var sendCount = 0;
        var service = new MacOSMediaPlaybackService(
            new StubServiceProvider(),
            NullLogger<MacOSMediaPlaybackService>.Instance,
            async (command, _) =>
            {
                if (command[0] == "send")
                {
                    if (Interlocked.Increment(ref sendCount) == 1)
                    {
                        firstStarted.SetResult();
                        await releaseFirst.Task;
                    }
                    else
                    {
                        secondStarted.SetResult();
                    }
                }
                return new MacOSMediaPlaybackService.AdapterCommandResult(0, "null", string.Empty, false);
            });

        var first = service.HandleActionAsync(CreateAction("next"), CancellationToken.None);
        await firstStarted.Task;
        var second = service.HandleActionAsync(CreateAction("next"), CancellationToken.None);

        Assert.False(secondStarted.Task.IsCompleted);
        releaseFirst.SetResult();
        await secondStarted.Task;
        await Task.WhenAll(first, second);
    }

    [Fact]
    public async Task HandleActionAsync_ReconcilesPlaybackImmediatelyAfterSuccess()
    {
        var syncService = new RecordingMediaPlaybackSyncService();
        var commands = new List<string[]>();
        var service = new MacOSMediaPlaybackService(
            new StubServiceProvider(syncService),
            NullLogger<MacOSMediaPlaybackService>.Instance,
            (command, _) =>
            {
                commands.Add(command.ToArray());
                var output = command[0] == "get"
                    ? """{"bundleIdentifier":"com.apple.Music","playing":false,"title":"Track","elapsedTime":12.0,"duration":180.0}"""
                    : string.Empty;
                return Task.FromResult(new MacOSMediaPlaybackService.AdapterCommandResult(0, output, string.Empty, false));
            });

        var result = await service.HandleActionAsync(CreateAction("pause"), CancellationToken.None);

        Assert.True(result.Success);
        Assert.Contains(commands, command => command.SequenceEqual(["get", "--now"]));
        var publication = Assert.Single(syncService.LocalEvents);
        Assert.Equal("posted", publication.EventType);
        Assert.Equal("paused", publication.Playback.PlaybackState);
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
    [InlineData("dev.rift.app", null)]
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

    private static PendingIncomingMediaPlaybackAction CreateAction(string action) => new()
    {
        RequestId = Guid.NewGuid().ToString("D"),
        OperationId = Guid.NewGuid().ToString("D"),
        SourceDeviceId = "rift-source",
        RequestingDeviceId = "rift-requester",
        PlaybackId = "playback-1",
        Action = action
    };

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
            $"#!/usr/bin/perl\nuse strict;\nuse warnings;\nmy $path = q{{{argsPath}}};\nopen(my $fh, '>>', $path) or die $!;\nforeach my $arg (@ARGV) {{ print $fh $arg . \"\\n\"; }}\nclose($fh);\nexit 0;\n");
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

    private sealed class StubServiceProvider(object? service = null) : IServiceProvider
    {
        public object? GetService(Type serviceType) =>
            service is not null && serviceType.IsInstanceOfType(service) ? service : null;
    }

    private sealed class RecordingMediaPlaybackSyncService : IMediaPlaybackSyncService
    {
        public List<(string EventType, MediaPlaybackRecord Playback)> LocalEvents { get; } = [];

        public Task<NotifyLocalMediaPlaybackEventResult> HandleLocalPlaybackEventAsync(
            string eventType,
            MediaPlaybackRecord playback,
            string? removedAt,
            CancellationToken cancellationToken)
        {
            LocalEvents.Add((eventType, playback));
            return Task.FromResult(new NotifyLocalMediaPlaybackEventResult { PlaybackId = playback.PlaybackId });
        }

        public Task PublishLocalPlaybackToPeerAsync(string peerDeviceId, MediaPlaybackRecord playback, CancellationToken cancellationToken) =>
            throw new NotSupportedException();

        public Task SendPeerErrorAsync(string peerDeviceId, string failureReason, string? refMessageId, string message, CancellationToken cancellationToken) =>
            throw new NotSupportedException();

        public Task<ListMediaPlaybackResult> ListMediaPlaybackAsync(CancellationToken cancellationToken) =>
            throw new NotSupportedException();

        public Task<MediaPlaybackRecord> GetMediaPlaybackAsync(string sourceDeviceId, string playbackId, CancellationToken cancellationToken) =>
            throw new NotSupportedException();

        public Task<PerformMediaPlaybackActionResult> PerformMediaPlaybackActionAsync(string sourceDeviceId, string playbackId, string action, long? positionMs, CancellationToken cancellationToken) =>
            throw new NotSupportedException();

        public Task HandleMediaPlaybackPostedAsync(MediaPlaybackRecord playback, CancellationToken cancellationToken) =>
            throw new NotSupportedException();

        public Task HandleMediaPlaybackUpdatedAsync(MediaPlaybackRecord playback, CancellationToken cancellationToken) =>
            throw new NotSupportedException();

        public Task HandleMediaPlaybackRemovedAsync(MediaPlaybackRemovedRecord playback, CancellationToken cancellationToken) =>
            throw new NotSupportedException();

        public Task HandleMediaPlaybackActionResultAsync(MediaPlaybackActionResultRecord result, CancellationToken cancellationToken) =>
            throw new NotSupportedException();

        public Task HandleMediaPlaybackActionRequestAsync(MediaPlaybackActionRequestRecord request, CancellationToken cancellationToken) =>
            throw new NotSupportedException();

        public Task<ReportHandledMediaPlaybackActionResult> ReportHandledMediaPlaybackActionAsync(
            string requestId,
            bool success,
            string? failureReason,
            string? message,
            CancellationToken cancellationToken) => throw new NotSupportedException();
    }
}
