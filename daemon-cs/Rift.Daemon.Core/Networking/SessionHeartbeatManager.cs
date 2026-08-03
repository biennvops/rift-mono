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

        if (!ShouldTrackPresence(args))
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
            tracked.WriteLastHeardTick(Environment.TickCount64);
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
        var now = Environment.TickCount64;
        var sendTasks = new List<Task>(_sessions.Count);

        foreach (var entry in _sessions)
        {
            var tracked = entry.Value;
            if (now - tracked.ReadLastSentTick() < HeartbeatCadence.TotalMilliseconds)
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
                Environment.TickCount64,
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

    private void MarkTimedOutSessionsOffline()
    {
        var now = Environment.TickCount64;
        foreach (var entry in _sessions)
        {
            if (now - entry.Value.ReadLastHeardTick() < OfflineThreshold.TotalMilliseconds)
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

    internal static bool ShouldTrackPresence(SessionStateChangedEventArgs args)
    {
        return args.AllowsProtectedTraffic && args.SelectedCapabilities.Contains(PresenceBasicCapability, StringComparer.Ordinal);
    }

    private sealed class TrackedSession
    {
        private long _lastSentTick;
        private long _lastHeardTick;

        public TrackedSession(IReadOnlyList<string> selectedCapabilities, long now)
        {
            SelectedCapabilities = selectedCapabilities;
            _lastSentTick = now - (long)HeartbeatCadence.TotalMilliseconds;
            _lastHeardTick = now;
        }

        public IReadOnlyList<string> SelectedCapabilities { get; }

        public long ReadLastSentTick() => Interlocked.Read(ref _lastSentTick);

        public void WriteLastSentTick(long value) => Interlocked.Exchange(ref _lastSentTick, value);

        public long ReadLastHeardTick() => Interlocked.Read(ref _lastHeardTick);

        public void WriteLastHeardTick(long value) => Interlocked.Exchange(ref _lastHeardTick, value);
    }
}
