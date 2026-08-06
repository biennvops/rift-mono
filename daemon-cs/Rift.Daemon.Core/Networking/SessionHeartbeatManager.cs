using System.Collections.Concurrent;
using System.Text;
using System.Text.Json;
using Rift.Daemon.Core.Interfaces;

namespace Rift.Daemon.Core.Networking;

internal sealed class SessionHeartbeatManager : IAsyncDisposable
{
    internal const string PresenceBasicCapability = "presence.basic";
    internal static readonly TimeSpan HeartbeatCadence = TimeSpan.FromSeconds(15);
    internal static readonly TimeSpan OfflineThreshold = TimeSpan.FromSeconds(45);

    private readonly ITransport _transport;
    private readonly IIdentityManager _identityManager;
    private readonly IPresenceService _presenceService;
    private readonly ConcurrentDictionary<string, TrackedSession> _sessions = new(StringComparer.Ordinal);
    private readonly Lock _sessionsGate = new();
    private readonly Lock _sync = new();
    private PeriodicTimer? _timer;
    private Task? _runLoopTask;
    private CancellationTokenSource? _runLoopCts;
    private readonly Func<long> _tickProvider;

    public SessionHeartbeatManager(
        ITransport transport,
        IIdentityManager identityManager,
        IPresenceService presenceService,
        Func<long>? tickProvider = null)
    {
        _transport = transport;
        _identityManager = identityManager;
        _presenceService = presenceService;
        _tickProvider = tickProvider ?? (() => Environment.TickCount64);
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
        var now = _tickProvider();
        lock (_sessionsGate)
        {
            if (!args.IsOnline)
            {
                _sessions.TryRemove(args.PeerDeviceId, out _);
                _presenceService.MarkPeerOffline(args.PeerDeviceId);
                return;
            }

            if (!ShouldTrackPresence(args))
            {
                _sessions.TryRemove(args.PeerDeviceId, out _);
                _presenceService.MarkPeerOffline(args.PeerDeviceId);
                return;
            }

            _sessions[args.PeerDeviceId] = new TrackedSession(args.SelectedCapabilities, now);
        }
    }

    public void ObserveAuthenticatedMessage(SessionPeerContext session)
    {
        if (_sessions.TryGetValue(session.PeerDeviceId, out var tracked))
        {
            tracked.MarkHeard(_tickProvider());
        }
    }

    private async Task RunAsync(CancellationToken cancellationToken)
    {
        var timer = _timer;

        try
        {
            while (timer is not null && await timer.WaitForNextTickAsync(cancellationToken))
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
        cancellationToken.ThrowIfCancellationRequested();
        var now = _tickProvider();
        var sendTasks = new List<Task>(_sessions.Count);

        foreach (var entry in _sessions)
        {
            var tracked = entry.Value;
            if (tracked.IsTimedOut ||
                now - tracked.ReadLastSentTick() < HeartbeatCadence.TotalMilliseconds)
            {
                continue;
            }

            sendTasks.Add(SendHeartbeatAsync(entry.Key, tracked, now, "online", cancellationToken));
        }

        await Task.WhenAll(sendTasks);
    }

    internal async Task SendOfflinePresenceAsync(CancellationToken cancellationToken)
    {
        var sendTasks = _sessions
            .Select(entry => SendHeartbeatAsync(
                entry.Key,
                entry.Value,
                _tickProvider(),
                "offline",
                cancellationToken))
            .ToArray();

        await Task.WhenAll(sendTasks);
    }

    private async Task SendHeartbeatAsync(
        string peerDeviceId,
        TrackedSession tracked,
        long now,
        string status,
        CancellationToken cancellationToken)
    {
        var envelope = new
        {
            rift = "0.1-draft",
            type = "presence.update",
            messageId = Guid.NewGuid().ToString("D"),
            sourceDeviceId = _identityManager.GetDeviceId(),
            payload = new
            {
                status,
                lastSeenAt = DateTimeOffset.UtcNow.ToString("O"),
                capabilities = tracked.SelectedCapabilities
            }
        };

        var payloadBytes = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(envelope));

        try
        {
            await _transport.SendAsync(peerDeviceId, payloadBytes, cancellationToken);
            tracked.WriteLastSentTick(now);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception)
        {
            // Transport teardown drives the actual offline transition.
        }
    }

    internal void MarkTimedOutSessionsOffline()
    {
        var now = _tickProvider();
        foreach (var entry in _sessions)
        {
            var lastHeardTick = entry.Value.ReadLastHeardTick();
            if (now - lastHeardTick < OfflineThreshold.TotalMilliseconds)
            {
                continue;
            }

            TryMarkSessionTimedOut(entry.Key, entry.Value, lastHeardTick);
        }
    }

    internal TrackedSession? GetTrackedSession(string peerDeviceId)
    {
        lock (_sessionsGate)
        {
            return _sessions.TryGetValue(peerDeviceId, out var tracked) ? tracked : null;
        }
    }

    internal bool TryMarkSessionTimedOut(
        string peerDeviceId,
        TrackedSession tracked,
        long observedLastHeardTick)
    {
        lock (_sessionsGate)
        {
            if (!_sessions.TryGetValue(peerDeviceId, out var current) ||
                !ReferenceEquals(current, tracked))
            {
                return false;
            }

            return tracked.TryMarkTimedOut(
                observedLastHeardTick,
                () => _presenceService.MarkPeerOffline(peerDeviceId));
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

    internal static bool ShouldTrackPresence(SessionStateChangedEventArgs args)
    {
        return args.AllowsProtectedTraffic && args.SelectedCapabilities.Contains(PresenceBasicCapability, StringComparer.Ordinal);
    }

    internal sealed class TrackedSession
    {
        private long _lastSentTick;
        private long _lastHeardTick;
        private int _timedOut;
        private readonly Lock _sync = new();

        public TrackedSession(IReadOnlyList<string> selectedCapabilities, long now)
        {
            SelectedCapabilities = selectedCapabilities;
            _lastSentTick = now - (long)HeartbeatCadence.TotalMilliseconds;
            _lastHeardTick = now;
        }

        public IReadOnlyList<string> SelectedCapabilities { get; }

        public bool IsTimedOut => Volatile.Read(ref _timedOut) != 0;

        public long ReadLastSentTick() => Interlocked.Read(ref _lastSentTick);

        public void WriteLastSentTick(long value) => Interlocked.Exchange(ref _lastSentTick, value);

        public long ReadLastHeardTick() => Interlocked.Read(ref _lastHeardTick);

        public void MarkHeard(long value)
        {
            lock (_sync)
            {
                Interlocked.Exchange(ref _lastHeardTick, value);
                Interlocked.Exchange(ref _timedOut, 0);
            }
        }

        public bool TryMarkTimedOut(long observedLastHeardTick, Action onTimedOut)
        {
            lock (_sync)
            {
                if (Interlocked.Read(ref _lastHeardTick) != observedLastHeardTick ||
                    Volatile.Read(ref _timedOut) != 0)
                {
                    return false;
                }

                Interlocked.Exchange(ref _timedOut, 1);
                onTimedOut();
                return true;
            }
        }
    }
}
