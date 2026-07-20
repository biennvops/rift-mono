using Rift.Daemon.Core.Interfaces;

namespace Rift.Daemon.Linux;

internal sealed class LinuxMediaPlaybackService(
    IServiceProvider serviceProvider,
    ILinuxMprisClient mprisClient,
    ILogger<LinuxMediaPlaybackService> logger) : ILocalMediaPlaybackActionHandler
{
    private static readonly TimeSpan PollInterval = TimeSpan.FromSeconds(1);

    private readonly Lock _gate = new();
    private readonly Dictionary<string, SnapshotState> _current = new(StringComparer.Ordinal);
    private CancellationTokenSource? _stoppingCts;
    private Task? _runTask;

    public void Start(CancellationToken cancellationToken)
    {
        if (_runTask is not null)
        {
            return;
        }

        logger.LogInformation("Starting Linux MPRIS media playback observer.");
        _stoppingCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        var transport = serviceProvider.GetRequiredService<ITransport>();
        transport.SessionStateChanged += OnSessionStateChanged;
        _stoppingCts.Token.Register(() => transport.SessionStateChanged -= OnSessionStateChanged);
        _runTask = Task.Run(() => RunAsync(_stoppingCts.Token), CancellationToken.None);
    }

    public async Task<LocalMediaPlaybackActionResult> HandleActionAsync(
        PendingIncomingMediaPlaybackAction request,
        CancellationToken cancellationToken)
    {
        try
        {
            await mprisClient.ExecuteActionAsync(
                request.PlaybackId,
                request.Action,
                request.PositionMs,
                cancellationToken).ConfigureAwait(false);
            return new LocalMediaPlaybackActionResult { Success = true };
        }
        catch (Exception ex) when (ex is not OperationCanceledException || !cancellationToken.IsCancellationRequested)
        {
            return new LocalMediaPlaybackActionResult
            {
                Success = false,
                FailureReason = "CapabilityUnavailable",
                Message = ex.Message
            };
        }
    }

    internal async Task PollOnceAsync(CancellationToken cancellationToken)
    {
        var snapshots = await mprisClient.GetSnapshotsAsync(cancellationToken).ConfigureAwait(false);
        var next = snapshots.ToDictionary(
            snapshot => snapshot.PlaybackId,
            snapshot => new SnapshotState(snapshot, CreateFingerprint(snapshot)),
            StringComparer.Ordinal);

        SnapshotState[] removed;
        SnapshotState[] posted;
        SnapshotState[] updated;
        lock (_gate)
        {
            removed = _current
                .Where(entry => !next.ContainsKey(entry.Key))
                .Select(entry => entry.Value)
                .ToArray();
            posted = next
                .Where(entry => !_current.ContainsKey(entry.Key))
                .Select(entry => entry.Value)
                .ToArray();
            updated = next
                .Where(entry => _current.TryGetValue(entry.Key, out var previous) &&
                                !string.Equals(previous.Fingerprint, entry.Value.Fingerprint, StringComparison.Ordinal))
                .Select(entry => entry.Value)
                .ToArray();
        }

        var syncService = serviceProvider.GetRequiredService<IMediaPlaybackSyncService>();
        foreach (var state in removed)
        {
            await syncService.HandleLocalPlaybackEventAsync(
                "removed",
                new MediaPlaybackRecord { PlaybackId = state.Snapshot.PlaybackId },
                DateTimeOffset.UtcNow.ToString("O"),
                cancellationToken).ConfigureAwait(false);
        }
        foreach (var state in posted)
        {
            await syncService.HandleLocalPlaybackEventAsync(
                "posted",
                state.Snapshot.ToRecord(),
                removedAt: null,
                cancellationToken).ConfigureAwait(false);
        }
        foreach (var state in updated)
        {
            await syncService.HandleLocalPlaybackEventAsync(
                "updated",
                state.Snapshot.ToRecord(),
                removedAt: null,
                cancellationToken).ConfigureAwait(false);
        }

        lock (_gate)
        {
            _current.Clear();
            foreach (var entry in next)
            {
                _current[entry.Key] = entry.Value;
            }
        }
    }

    private void OnSessionStateChanged(object? sender, SessionStateChangedEventArgs args)
    {
        if (!args.IsOnline ||
            !args.AllowsProtectedTraffic ||
            !args.SelectedCapabilities.Contains("media.playback", StringComparer.Ordinal))
        {
            return;
        }

        _ = RepublishCurrentPlaybackAsync(args.PeerDeviceId, _stoppingCts!.Token);
    }

    private async Task RepublishCurrentPlaybackAsync(
        string peerDeviceId,
        CancellationToken cancellationToken)
    {
        MediaPlaybackRecord[] playbacks;
        lock (_gate)
        {
            playbacks = _current.Values
                .Select(state => state.Snapshot.ToRecord())
                .ToArray();
        }

        foreach (var playback in playbacks)
        {
            try
            {
                await serviceProvider.GetRequiredService<IMediaPlaybackSyncService>()
                    .PublishLocalPlaybackToPeerAsync(
                        peerDeviceId,
                        playback,
                        cancellationToken).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                return;
            }
            catch (Exception ex)
            {
                logger.LogDebug(
                    ex,
                    "Failed to republish Linux media playback {PlaybackId} to {PeerDeviceId}.",
                    playback.PlaybackId,
                    peerDeviceId);
            }
        }
    }

    private async Task RunAsync(CancellationToken stoppingToken)
    {
        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                await PollOnceAsync(stoppingToken).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
            {
                break;
            }
            catch (Exception ex)
            {
                logger.LogDebug(ex, "Failed to poll Linux MPRIS playback state.");
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

    internal static string CreateFingerprint(LinuxMprisSnapshot snapshot)
    {
        var positionBucket = snapshot.PositionMs / 5000L;
        return string.Join('\n',
            snapshot.PlaybackId,
            snapshot.AppId,
            snapshot.AppName,
            snapshot.Title ?? string.Empty,
            snapshot.Artist ?? string.Empty,
            snapshot.Album ?? string.Empty,
            snapshot.PlaybackState,
            positionBucket,
            snapshot.DurationMs ?? -1L,
            snapshot.CanPlay,
            snapshot.CanPause,
            snapshot.CanSkipNext,
            snapshot.CanSkipPrevious,
            snapshot.CanSeek);
    }

    private sealed record SnapshotState(LinuxMprisSnapshot Snapshot, string Fingerprint);
}
