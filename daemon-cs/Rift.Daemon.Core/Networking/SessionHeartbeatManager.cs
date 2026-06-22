using System.Collections.Concurrent;
using System.Text;
using System.Text.Json;
using Rift.Daemon.Core.Interfaces;

namespace Rift.Daemon.Core.Networking;

internal sealed class SessionHeartbeatManager : IAsyncDisposable
{
    private static readonly TimeSpan HeartbeatCadence = TimeSpan.FromSeconds(30);
    private static readonly TimeSpan OfflineThreshold = TimeSpan.FromSeconds(90);

    private readonly ITransport _transport;
    private readonly IIdentityManager _identityManager;
    private readonly IPresenceService _presenceService;
    private readonly ConcurrentDictionary<string, TrackedSession> _sessions = new(StringComparer.Ordinal);
    private readonly Lock _sync = new();
    private PeriodicTimer? _timer;
    private Task? _runLoopTask;
    private CancellationTokenSource? _runLoopCts;

    public SessionHeartbeatManager(ITransport transport, IIdentityManager identityManager, IPresenceService presenceService)
    {
        _transport = transport;
        _identityManager = identityManager;
        _presenceService = presenceService;
    }

    public void EnsureStarted(CancellationToken stoppingToken)
    {
        lock (_sync)
        {
            if (_runLoopTask is not null)
            {
                return;
            }

            _runLoopCts = CancellationTokenSource.CreateLinkedTokenSource(stoppingToken);
            _timer = new PeriodicTimer(HeartbeatCadence);
            _runLoopTask = RunAsync(_runLoopCts.Token);
        }
    }

    public void OnSessionStateChanged(SessionStateChangedEventArgs args)
    {
        var now = Environment.TickCount64;
        if (!args.IsOnline)
        {
            _sessions.TryRemove(args.PeerDeviceId, out _);
            _presenceService.MarkPeerOffline(args.PeerDeviceId);
            return;
        }

        if (!args.AllowsProtectedTraffic || !args.SelectedCapabilities.Contains("presence.basic", StringComparer.Ordinal))
        {
            _sessions.TryRemove(args.PeerDeviceId, out _);
            return;
        }

        _sessions[args.PeerDeviceId] = new TrackedSession(args.SelectedCapabilities, now);
    }

    public void ObserveAuthenticatedMessage(SessionPeerContext session)
    {
        if (_sessions.TryGetValue(session.PeerDeviceId, out var tracked))
        {
            tracked.LastHeardTick = Environment.TickCount64;
        }
    }

    private async Task RunAsync(CancellationToken cancellationToken)
    {
        try
        {
            while (_timer is not null && await _timer.WaitForNextTickAsync(cancellationToken))
            {
                await EmitHeartbeatsAsync(cancellationToken);
                MarkTimedOutSessionsOffline();
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            // Normal shutdown.
        }
    }

    private async Task EmitHeartbeatsAsync(CancellationToken cancellationToken)
    {
        var now = Environment.TickCount64;

        foreach (var entry in _sessions)
        {
            var tracked = entry.Value;
            if (now - tracked.LastSentTick < HeartbeatCadence.TotalMilliseconds)
            {
                continue;
            }

            var envelope = new
            {
                rift = "0.1-draft",
                type = "presence.update",
                messageId = Guid.NewGuid().ToString("D"),
                sourceDeviceId = _identityManager.GetDeviceId(),
                payload = new
                {
                    status = "online",
                    lastSeenAt = DateTimeOffset.UtcNow.ToString("O"),
                    capabilities = tracked.SelectedCapabilities
                }
            };

            var payloadBytes = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(envelope));

            try
            {
                await _transport.SendAsync(entry.Key, payloadBytes, cancellationToken);
                tracked.LastSentTick = now;
            }
            catch (Exception)
            {
                // Transport teardown drives the actual offline transition.
            }
        }
    }

    private void MarkTimedOutSessionsOffline()
    {
        var now = Environment.TickCount64;
        foreach (var entry in _sessions)
        {
            if (now - entry.Value.LastHeardTick < OfflineThreshold.TotalMilliseconds)
            {
                continue;
            }

            if (_sessions.TryRemove(entry.Key, out _))
            {
                _presenceService.MarkPeerOffline(entry.Key);
            }
        }
    }

    public async ValueTask DisposeAsync()
    {
        Task? runLoopTask;
        CancellationTokenSource? runLoopCts;
        PeriodicTimer? timer;

        lock (_sync)
        {
            runLoopTask = _runLoopTask;
            runLoopCts = _runLoopCts;
            timer = _timer;
            _runLoopTask = null;
            _runLoopCts = null;
            _timer = null;
        }

        if (runLoopCts is not null)
        {
            await runLoopCts.CancelAsync();
            runLoopCts.Dispose();
        }

        timer?.Dispose();

        if (runLoopTask is not null)
        {
            await runLoopTask;
        }
    }

    private sealed class TrackedSession
    {
        public TrackedSession(IReadOnlyList<string> selectedCapabilities, long now)
        {
            SelectedCapabilities = selectedCapabilities;
            LastSentTick = now - (long)HeartbeatCadence.TotalMilliseconds;
            LastHeardTick = now;
        }

        public IReadOnlyList<string> SelectedCapabilities { get; }

        public long LastSentTick { get; set; }

        public long LastHeardTick { get; set; }
    }
}
