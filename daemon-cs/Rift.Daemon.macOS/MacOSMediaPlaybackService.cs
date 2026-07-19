using System.Diagnostics;
using System.Text.Json;
using Rift.Daemon.Core.Interfaces;

namespace Rift.Daemon.macOS;

internal sealed class MacOSMediaPlaybackService(
    IServiceProvider serviceProvider,
    ILogger<MacOSMediaPlaybackService> logger) : ILocalMediaPlaybackActionHandler
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);
    private static readonly TimeSpan PollInterval = TimeSpan.FromSeconds(1);
    private static readonly TimeSpan AdapterCommandTimeout = TimeSpan.FromSeconds(5);

    private readonly Lock _gate = new();
    private SnapshotState? _current;
    private CancellationTokenSource? _stoppingCts;
    private Task? _runTask;

    public void Start(CancellationToken cancellationToken)
    {
        if (_runTask is not null)
        {
            return;
        }

        logger.LogInformation("Starting macOS media playback observer.");
        _stoppingCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        _runTask = Task.Run(() => RunAsync(_stoppingCts.Token), CancellationToken.None);
    }

    private async Task RunAsync(CancellationToken stoppingToken)
    {
        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                var snapshot = await TryGetSnapshotAsync(stoppingToken).ConfigureAwait(false);
                await PublishIfChangedAsync(snapshot, stoppingToken).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
            {
                break;
            }
            catch (Exception ex)
            {
                logger.LogDebug(ex, "Failed to poll macOS media playback state.");
            }

            try
            {
                await Task.Delay(PollInterval, stoppingToken).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
            {
                break;
            }
        }
    }

    public async Task<LocalMediaPlaybackActionResult> HandleActionAsync(
        PendingIncomingMediaPlaybackAction request,
        CancellationToken cancellationToken)
    {
        string[]? command = request.Action switch
        {
            "play" => ["send", "0"],
            "pause" => ["send", "1"],
            "togglePlayPause" => ["send", "2"],
            "next" => ["send", "4"],
            "previous" => ["send", "5"],
            "seek" when request.PositionMs.HasValue => ["seek", checked((request.PositionMs.Value * 1000L)).ToString(System.Globalization.CultureInfo.InvariantCulture)],
            _ => null
        };

        if (command is null)
        {
            return new LocalMediaPlaybackActionResult
            {
                Success = false,
                FailureReason = "CapabilityUnavailable",
                Message = $"Unsupported macOS media playback action '{request.Action}'."
            };
        }

        var output = await RunAdapterAsync(command, cancellationToken).ConfigureAwait(false);
        if (output.ExitCode != 0)
        {
            return new LocalMediaPlaybackActionResult
            {
                Success = false,
                FailureReason = "CapabilityUnavailable",
                Message = string.IsNullOrWhiteSpace(output.StandardError) ? "MediaRemote adapter command failed." : output.StandardError
            };
        }

        return new LocalMediaPlaybackActionResult { Success = true };
    }

    private async Task PublishIfChangedAsync(MacOSNowPlayingSnapshot? snapshot, CancellationToken cancellationToken)
    {
        SnapshotState? previous;
        SnapshotState? next;
        string? eventType = null;

        lock (_gate)
        {
            previous = _current;
            if (snapshot is null)
            {
                if (previous is not null)
                {
                    _current = null;
                    eventType = "removed";
                }

                next = null;
            }
            else
            {
                next = new SnapshotState(snapshot, CreateFingerprint(snapshot));
                if (previous is null || !string.Equals(previous.Snapshot.PlaybackId, next.Snapshot.PlaybackId, StringComparison.Ordinal))
                {
                    _current = next;
                    eventType = "posted";
                }
                else if (!string.Equals(previous.Fingerprint, next.Fingerprint, StringComparison.Ordinal))
                {
                    _current = next;
                    eventType = "updated";
                }
            }
        }

        if (eventType is null)
        {
            return;
        }

        if (eventType == "removed")
        {
            await serviceProvider.GetRequiredService<IMediaPlaybackSyncService>().HandleLocalPlaybackEventAsync(
                "removed",
                new MediaPlaybackRecord { PlaybackId = previous!.Snapshot.PlaybackId },
                DateTimeOffset.UtcNow.ToString("O"),
                cancellationToken).ConfigureAwait(false);
            return;
        }

        await serviceProvider.GetRequiredService<IMediaPlaybackSyncService>().HandleLocalPlaybackEventAsync(
            eventType,
            next!.Snapshot.ToRecord(),
            removedAt: null,
            cancellationToken).ConfigureAwait(false);
    }

    private async Task<MacOSNowPlayingSnapshot?> TryGetSnapshotAsync(CancellationToken cancellationToken)
    {
        var output = await RunAdapterAsync(["get"], cancellationToken).ConfigureAwait(false);
        if (output.ExitCode != 0)
        {
            if (!output.MissingArtifacts)
            {
                logger.LogDebug("MediaRemote adapter get failed: {Error}", output.StandardError);
            }
            return null;
        }

        if (string.IsNullOrWhiteSpace(output.StandardOutput) || string.Equals(output.StandardOutput, "null", StringComparison.Ordinal))
        {
            return null;
        }

        var payload = JsonSerializer.Deserialize<AdapterNowPlayingPayload>(output.StandardOutput, JsonOptions);
        if (payload is null || string.IsNullOrWhiteSpace(payload.Title))
        {
            return null;
        }

        var appId = !string.IsNullOrWhiteSpace(payload.BundleIdentifier)
            ? payload.BundleIdentifier
            : payload.ProcessIdentifier.HasValue
                ? $"pid:{payload.ProcessIdentifier.Value}"
                : "system.nowplaying";
        var appName = !string.IsNullOrWhiteSpace(payload.BundleIdentifier)
            ? payload.BundleIdentifier
            : "Now Playing";
        var playbackState = payload.Playing == true ? "playing" : ((payload.ElapsedTime ?? 0) > 0 ? "paused" : "stopped");
        var playbackKey = payload.ContentItemIdentifier ?? payload.Title;
        var playbackId = string.Join(":", appId, playbackKey, payload.Artist ?? string.Empty);
        var durationMs = payload.Duration.HasValue ? Math.Max(0L, (long)Math.Round(payload.Duration.Value * 1000d)) : (long?)null;
        var positionMs = GetPositionMs(payload.ElapsedTimeNow, payload.ElapsedTime);
        var canSkip = payload.ProhibitsSkip != true;

        return new MacOSNowPlayingSnapshot(
            PlaybackId: playbackId,
            AppId: appId,
            AppName: appName,
            Title: payload.Title,
            Artist: payload.Artist,
            Album: payload.Album,
            Artwork: CreateArtwork(payload),
            PlaybackState: playbackState,
            PositionMs: positionMs,
            DurationMs: durationMs,
            CanPlay: playbackState != "playing",
            CanPause: playbackState == "playing",
            CanSkipNext: canSkip,
            CanSkipPrevious: canSkip,
            CanSeek: durationMs is > 0,
            UpdatedAt: DateTimeOffset.UtcNow.ToString("O"));
    }

    internal static long GetPositionMs(double? elapsedTimeNow, double? elapsedTime) =>
        Math.Max(0L, (long)Math.Round((elapsedTimeNow ?? elapsedTime ?? 0d) * 1000d));

    private static string CreateFingerprint(MacOSNowPlayingSnapshot snapshot)
    {
        var positionBucket = snapshot.PositionMs / 5000;
        return string.Join('\n',
            snapshot.PlaybackId,
            snapshot.AppId,
            snapshot.AppName,
            snapshot.Title ?? string.Empty,
            snapshot.Artist ?? string.Empty,
            snapshot.Album ?? string.Empty,
            snapshot.PlaybackState,
            positionBucket.ToString(System.Globalization.CultureInfo.InvariantCulture),
            (snapshot.DurationMs ?? -1).ToString(System.Globalization.CultureInfo.InvariantCulture),
            snapshot.CanPlay,
            snapshot.CanPause,
            snapshot.CanSkipNext,
            snapshot.CanSkipPrevious,
            snapshot.CanSeek);
    }

    private static (string ScriptPath, string FrameworkPath)? ResolveAdapterPaths()
    {
        var scriptPath = Environment.GetEnvironmentVariable("RIFT_MEDIAREMOTE_SCRIPT");
        var frameworkPath = Environment.GetEnvironmentVariable("RIFT_MEDIAREMOTE_FRAMEWORK");
        if (!string.IsNullOrWhiteSpace(scriptPath) && !string.IsNullOrWhiteSpace(frameworkPath))
        {
            return (scriptPath, frameworkPath);
        }

        var baseDirectory = AppContext.BaseDirectory;
        var adapterDirectory = Path.Combine(baseDirectory, "MediaRemoteAdapter");
        var bundledScript = Path.Combine(adapterDirectory, "mediaremote-adapter.pl");
        var bundledFramework = Path.Combine(adapterDirectory, "MediaRemoteAdapter.framework");
        if (File.Exists(bundledScript) && Directory.Exists(bundledFramework))
        {
            return (bundledScript, bundledFramework);
        }

        return null;
    }

    private async Task<AdapterCommandResult> RunAdapterAsync(IReadOnlyList<string> command, CancellationToken cancellationToken)
    {
        var paths = ResolveAdapterPaths();
        if (paths is null)
        {
            return AdapterCommandResult.MissingArtifactsResult;
        }

        var startInfo = new ProcessStartInfo
        {
            FileName = "/usr/bin/perl",
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true
        };
        startInfo.ArgumentList.Add(paths.Value.ScriptPath);
        startInfo.ArgumentList.Add(paths.Value.FrameworkPath);
        foreach (var part in command)
        {
            startInfo.ArgumentList.Add(part);
        }

        using var process = new Process { StartInfo = startInfo };
        process.Start();
        var stdoutTask = process.StandardOutput.ReadToEndAsync();
        var stderrTask = process.StandardError.ReadToEndAsync();

        using var timeoutCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeoutCts.CancelAfter(AdapterCommandTimeout);

        try
        {
            await process.WaitForExitAsync(timeoutCts.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            try
            {
                if (!process.HasExited)
                {
                    process.Kill(entireProcessTree: true);
                }
            }
            catch
            {
            }

            return new AdapterCommandResult(
                ExitCode: -1,
                StandardOutput: string.Empty,
                StandardError: $"MediaRemote adapter command timed out after {AdapterCommandTimeout.TotalSeconds:0} seconds.",
                MissingArtifacts: false);
        }

        return new AdapterCommandResult(
            process.ExitCode,
            (await stdoutTask.ConfigureAwait(false)).Trim(),
            (await stderrTask.ConfigureAwait(false)).Trim(),
            MissingArtifacts: false);
    }

    private sealed record SnapshotState(MacOSNowPlayingSnapshot Snapshot, string Fingerprint);

    private sealed record AdapterCommandResult(int ExitCode, string StandardOutput, string StandardError, bool MissingArtifacts)
    {
        public static AdapterCommandResult MissingArtifactsResult { get; } = new(
            ExitCode: -1,
            StandardOutput: string.Empty,
            StandardError: "MediaRemote adapter artifacts are not bundled.",
            MissingArtifacts: true);
    }

    private static IReadOnlyDictionary<string, object?>? CreateArtwork(AdapterNowPlayingPayload payload)
    {
        if (string.IsNullOrWhiteSpace(payload.ArtworkData) || string.IsNullOrWhiteSpace(payload.ArtworkMimeType))
        {
            return null;
        }

        return new Dictionary<string, object?>
        {
            ["dataBase64"] = payload.ArtworkData,
            ["mediaType"] = payload.ArtworkMimeType
        };
    }

    private sealed class AdapterNowPlayingPayload
    {
        public string? BundleIdentifier { get; init; }
        public bool? Playing { get; init; }
        public string? Title { get; init; }
        public string? Artist { get; init; }
        public string? Album { get; init; }
        public string? ArtworkData { get; init; }
        public string? ArtworkMimeType { get; init; }
        public double? Duration { get; init; }
        public double? ElapsedTime { get; init; }
        public double? ElapsedTimeNow { get; init; }
        public bool? ProhibitsSkip { get; init; }
        public string? ContentItemIdentifier { get; init; }
        public int? ProcessIdentifier { get; init; }
    }

    private sealed record MacOSNowPlayingSnapshot(
        string PlaybackId,
        string AppId,
        string AppName,
        string? Title,
        string? Artist,
        string? Album,
        IReadOnlyDictionary<string, object?>? Artwork,
        string PlaybackState,
        long PositionMs,
        long? DurationMs,
        bool CanPlay,
        bool CanPause,
        bool CanSkipNext,
        bool CanSkipPrevious,
        bool CanSeek,
        string UpdatedAt)
    {
        public MediaPlaybackRecord ToRecord() => new()
        {
            PlaybackId = PlaybackId,
            SourcePlatform = "macos",
            AppId = AppId,
            AppName = AppName,
            Title = Title,
            Artist = Artist,
            Album = Album,
            Artwork = Artwork,
            PlaybackState = PlaybackState,
            PositionMs = PositionMs,
            DurationMs = DurationMs,
            CanPlay = CanPlay,
            CanPause = CanPause,
            CanSkipNext = CanSkipNext,
            CanSkipPrevious = CanSkipPrevious,
            CanSeek = CanSeek,
            UpdatedAt = UpdatedAt
        };
    }
}
