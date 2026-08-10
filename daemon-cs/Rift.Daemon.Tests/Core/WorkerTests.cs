using System.Collections.Concurrent;
using System.Text;
using System.Text.Json;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;
using Rift.Daemon.Core;
using Rift.Daemon.Core.Cryptography;
using Rift.Daemon.Core.Interfaces;
using Rift.Daemon.Core.Networking;

namespace Rift.Daemon.Tests.Core;

public sealed class WorkerTests
{
    [Fact]
    public async Task SessionOnline_UpdatesPresenceAndBroadcastsPresenceUpdate()
    {
        var ipcListener = new FakeIpcListener();
        var discoveryService = new FakeDiscoveryService();
        var trustStore = new FakeTrustStore();
        var transport = new FakeTransport();
        var protocolRouter = new FakeProtocolMessageRouter();
        var presenceService = new PresenceService();
        var identityManager = new IdentityManager();
        await using var worker = new TestWorker(
            NullLogger<Worker>.Instance,
            ipcListener,
            identityManager,
            trustStore,
            discoveryService,
            transport,
            protocolRouter,
            presenceService);

        await worker.StartAsync(CancellationToken.None);
        await WaitUntilAsync(() => discoveryService.StartAdvertisingCalled);

        transport.EmitSessionStateChanged("rift-peer-online", isOnline: true, ["clipboard.offer_fetch", "presence.basic", "operation.lifecycle", "security.event_log"], allowsProtectedTraffic: true);

        await WaitUntilAsync(() => transport.SentMessages.Count > 0);

        var presence = presenceService.GetPeerPresence("rift-peer-online");
        Assert.NotNull(presence);
        Assert.Equal("online", presence!.Status);
        Assert.Contains("clipboard.offer_fetch", presence.Capabilities);
        Assert.True(discoveryService.StartAdvertisingCalled);
        Assert.True(discoveryService.StartDiscoveryCalled);
        Assert.Contains(transport.SentMessages, message =>
            message.PeerDeviceId == "rift-peer-online" &&
            message.Type == "presence.update" &&
            message.Capabilities.Contains("presence.basic"));

        await worker.StopAsync(CancellationToken.None);
        Assert.True(discoveryService.StopAdvertisingCalled);
        Assert.True(discoveryService.StopDiscoveryCalled);
    }

    [Fact]
    public async Task SessionOffline_MarksPeerOffline()
    {
        var ipcListener = new FakeIpcListener();
        var discoveryService = new FakeDiscoveryService();
        var trustStore = new FakeTrustStore();
        var transport = new FakeTransport();
        var protocolRouter = new FakeProtocolMessageRouter();
        var presenceService = new PresenceService();
        var identityManager = new IdentityManager();
        await using var worker = new TestWorker(
            NullLogger<Worker>.Instance,
            ipcListener,
            identityManager,
            trustStore,
            discoveryService,
            transport,
            protocolRouter,
            presenceService);

        await worker.StartAsync(CancellationToken.None);
        await WaitUntilAsync(() => discoveryService.StartAdvertisingCalled);

        transport.EmitSessionStateChanged("rift-peer-offline", isOnline: true, ["clipboard.offer_fetch", "presence.basic", "operation.lifecycle", "security.event_log"], allowsProtectedTraffic: true);
        await WaitUntilAsync(() => presenceService.GetPeerPresence("rift-peer-offline")?.Status == "online");

        transport.EmitSessionStateChanged("rift-peer-offline", isOnline: false, ["clipboard.offer_fetch", "presence.basic", "operation.lifecycle", "security.event_log"], allowsProtectedTraffic: true);
        await WaitUntilAsync(() => presenceService.GetPeerPresence("rift-peer-offline")?.Status == "offline");

        var presence = presenceService.GetPeerPresence("rift-peer-offline");
        Assert.NotNull(presence);
        Assert.Equal("offline", presence!.Status);
        Assert.Contains("presence.basic", presence.Capabilities);

        await worker.StopAsync(CancellationToken.None);
    }

    [Fact]
    public async Task SessionOnline_DoesNotBroadcastPresenceForDiagnosticOnlySession()
    {
        var ipcListener = new FakeIpcListener();
        var discoveryService = new FakeDiscoveryService();
        var trustStore = new FakeTrustStore();
        var transport = new FakeTransport();
        var protocolRouter = new FakeProtocolMessageRouter();
        var presenceService = new PresenceService();
        var identityManager = new IdentityManager();
        await using var worker = new TestWorker(
            NullLogger<Worker>.Instance,
            ipcListener,
            identityManager,
            trustStore,
            discoveryService,
            transport,
            protocolRouter,
            presenceService);

        await worker.StartAsync(CancellationToken.None);
        await WaitUntilAsync(() => discoveryService.StartAdvertisingCalled);

        transport.EmitSessionStateChanged("rift-peer-diagnostic", isOnline: true, ["presence.basic"], allowsProtectedTraffic: false);
        await Task.Delay(150);

        Assert.DoesNotContain(transport.SentMessages, message => message.PeerDeviceId == "rift-peer-diagnostic" && message.Type == "presence.update");

        await worker.StopAsync(CancellationToken.None);
    }

    [Fact]
    public async Task TransportMessageReceived_RoutesPayloadToProtocolRouter()
    {
        var ipcListener = new FakeIpcListener();
        var discoveryService = new FakeDiscoveryService();
        var trustStore = new FakeTrustStore();
        var transport = new FakeTransport();
        var protocolRouter = new FakeProtocolMessageRouter();
        var presenceService = new PresenceService();
        var identityManager = new IdentityManager();
        await using var worker = new TestWorker(
            NullLogger<Worker>.Instance,
            ipcListener,
            identityManager,
            trustStore,
            discoveryService,
            transport,
            protocolRouter,
            presenceService);

        await worker.StartAsync(CancellationToken.None);
        await WaitUntilAsync(() => discoveryService.StartAdvertisingCalled);

        var payload = Encoding.UTF8.GetBytes("""{"type":"presence.update","payload":{"status":"online","capabilities":["presence.basic"]}}""");
        transport.EmitMessageReceived("rift-peer-router", payload);

        await WaitUntilAsync(() => protocolRouter.Messages.Count > 0);

        Assert.Contains(protocolRouter.Messages, message =>
                message.PeerDeviceId == "rift-peer-router" &&
                message.Payload == Encoding.UTF8.GetString(payload));

        await worker.StopAsync(CancellationToken.None);
    }

    [Fact]
    public async Task TransportMessageReceived_SerializesMessagesFromSamePeer()
    {
        var ipcListener = new FakeIpcListener();
        var discoveryService = new FakeDiscoveryService();
        var trustStore = new FakeTrustStore();
        var transport = new FakeTransport();
        var protocolRouter = new BlockingProtocolMessageRouter();
        var presenceService = new PresenceService();
        var identityManager = new IdentityManager();
        await using var worker = new TestWorker(
            NullLogger<Worker>.Instance,
            ipcListener,
            identityManager,
            trustStore,
            discoveryService,
            transport,
            protocolRouter,
            presenceService);

        await worker.StartAsync(CancellationToken.None);
        await WaitUntilAsync(() => discoveryService.StartAdvertisingCalled);

        transport.EmitMessageReceived("rift-peer-router", Encoding.UTF8.GetBytes("first"));
        await protocolRouter.FirstMessageStarted;

        transport.EmitMessageReceived("rift-peer-router", Encoding.UTF8.GetBytes("second"));
        await Task.Delay(100);

        Assert.Equal(1, protocolRouter.StartedCount);

        protocolRouter.ReleaseFirstMessage();
        await WaitUntilAsync(() => protocolRouter.Messages.Count == 2);

        Assert.Equal(["first", "second"], protocolRouter.Messages.Select(message => message.Payload).ToArray());

        await worker.StopAsync(CancellationToken.None);
    }

    [Fact]
    public async Task ExecuteAsync_ObservesFaultedSiblingTaskWhenOtherTaskCompletesFirst()
    {
        var logger = new ListLogger<Worker>();
        var ipcListener = new DelayedFaultIpcListener(TimeSpan.FromMilliseconds(50), new InvalidOperationException("ipc boom"));
        var discoveryService = new FakeDiscoveryService();
        var trustStore = new FakeTrustStore();
        var transport = new CompletingTransport();
        var protocolRouter = new FakeProtocolMessageRouter();
        var presenceService = new PresenceService();
        var identityManager = new IdentityManager();
        await using var worker = new TestWorker(
            logger,
            ipcListener,
            identityManager,
            trustStore,
            discoveryService,
            transport,
            protocolRouter,
            presenceService);

        await worker.RunExecuteAsync(CancellationToken.None);
        await ipcListener.Faulted.Task;
        await WaitUntilAsync(() => logger.Entries.Any(entry =>
            entry.LogLevel == LogLevel.Error &&
            entry.Exception?.ToString().Contains("ipc boom", StringComparison.Ordinal) == true &&
            entry.Message.Contains("IPC listener", StringComparison.Ordinal)));

        Assert.Contains(logger.Entries, entry =>
            entry.LogLevel == LogLevel.Error &&
            entry.Exception?.ToString().Contains("ipc boom", StringComparison.Ordinal) == true &&
            entry.Message.Contains("IPC listener", StringComparison.Ordinal));
    }

    [Fact]
    public async Task ExecuteAsync_ReconnectsTrustedPeerAtStartup()
    {
        const string peerDeviceId = "rift-zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz";
        var ipcListener = new FakeIpcListener();
        var discoveryService = new FakeDiscoveryService();
        var trustStore = new FakeTrustStore();
        trustStore.Peers.Add(new PeerIdentity
        {
            DeviceId = peerDeviceId,
            Ed25519PublicKey = new byte[32],
            State = TrustState.Trusted,
            LastStateTransitionAt = DateTimeOffset.UtcNow,
            TrustedEndpoints =
            [
                new TrustedPeerEndpoint
                {
                    Address = "192.168.2.68",
                    Port = 9140,
                    Source = "pairing-session",
                    LastSuccessAt = DateTimeOffset.UtcNow
                }
            ]
        });
        var transport = new FakeTransport { ConnectedDeviceId = peerDeviceId };
        await using var worker = new TestWorker(
            NullLogger<Worker>.Instance,
            ipcListener,
            new IdentityManager(),
            trustStore,
            discoveryService,
            transport,
            new FakeProtocolMessageRouter(),
            new PresenceService());

        await worker.StartAsync(CancellationToken.None);
        await WaitUntilAsync(() => transport.ConnectAttempts.Count > 0);

        Assert.Contains(transport.ConnectAttempts, attempt =>
            attempt.Host == "192.168.2.68" &&
            attempt.Port == 9140 &&
            attempt.ExpectedDeviceId == peerDeviceId);
        Assert.True(transport.HasActiveSession(peerDeviceId));

        await worker.StopAsync(CancellationToken.None);
    }

    [Fact]
    public async Task ExecuteAsync_QuarantinesCompletedIdentityMismatchWhenAnotherEndpointSucceeds()
    {
        const string peerDeviceId = "rift-zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz";
        var trustStore = new FakeTrustStore();
        var peer = new PeerIdentity
        {
            DeviceId = peerDeviceId,
            Ed25519PublicKey = new byte[32],
            State = TrustState.Trusted,
            LastStateTransitionAt = DateTimeOffset.UtcNow,
            TrustedEndpoints =
            [
                new TrustedPeerEndpoint
                {
                    Address = "192.168.2.68",
                    Port = 9140,
                    Source = "session-established",
                    LastSuccessAt = DateTimeOffset.UtcNow
                },
                new TrustedPeerEndpoint
                {
                    Address = "192.168.2.69",
                    Port = 9140,
                    Source = "session-established",
                    LastSuccessAt = DateTimeOffset.UtcNow.AddMinutes(-1)
                }
            ]
        };
        trustStore.Peers.Add(peer);
        var transport = new FakeTransport
        {
            ConnectedDeviceId = peerDeviceId,
            UnexpectedIdentityHost = "192.168.2.69"
        };
        await using var worker = new TestWorker(
            NullLogger<Worker>.Instance,
            new FakeIpcListener(),
            new IdentityManager(),
            trustStore,
            new FakeDiscoveryService(),
            transport,
            new FakeProtocolMessageRouter(),
            new PresenceService());

        await worker.StartAsync(CancellationToken.None);
        await WaitUntilAsync(() => trustStore.SaveCount > 0);

        Assert.Single(peer.TrustedEndpoints);
        Assert.Equal("192.168.2.68", peer.TrustedEndpoints[0].Address);
        Assert.True(transport.HasActiveSession(peerDeviceId));

        await worker.StopAsync(CancellationToken.None);
    }

    [Fact]
    public async Task SessionOffline_ReconnectsTrustedPeerWithoutDaemonRestart()
    {
        const string peerDeviceId = "rift-zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz";
        var ipcListener = new FakeIpcListener();
        var discoveryService = new FakeDiscoveryService();
        var trustStore = new FakeTrustStore();
        trustStore.Peers.Add(new PeerIdentity
        {
            DeviceId = peerDeviceId,
            Ed25519PublicKey = new byte[32],
            State = TrustState.Trusted,
            LastStateTransitionAt = DateTimeOffset.UtcNow,
            TrustedEndpoints =
            [
                new TrustedPeerEndpoint
                {
                    Address = "192.168.2.68",
                    Port = 9140,
                    Source = "pairing-session",
                    LastSuccessAt = DateTimeOffset.UtcNow
                }
            ]
        });
        var transport = new FakeTransport { ConnectedDeviceId = peerDeviceId };
        transport.SetActiveSession(peerDeviceId, true);
        await using var worker = new TestWorker(
            NullLogger<Worker>.Instance,
            ipcListener,
            new IdentityManager(),
            trustStore,
            discoveryService,
            transport,
            new FakeProtocolMessageRouter(),
            new PresenceService());

        await worker.StartAsync(CancellationToken.None);
        await WaitUntilAsync(() => discoveryService.StartAdvertisingCalled);
        transport.EmitSessionStateChanged(
            peerDeviceId,
            isOnline: false,
            ["presence.basic"],
            allowsProtectedTraffic: true);

        await WaitUntilAsync(() => transport.ConnectAttempts.Count > 0);

        Assert.True(transport.HasActiveSession(peerDeviceId));

        await worker.StopAsync(CancellationToken.None);
    }

    [Fact]
    public async Task ExecuteAsync_DoesNotAutoStartDiscovery_WhenKnownManagedPeersExist()
    {
        var ipcListener = new FakeIpcListener();
        var discoveryService = new FakeDiscoveryService();
        var trustStore = new FakeTrustStore();
        trustStore.Peers.Add(new PeerIdentity
        {
            DeviceId = "rift-known-peer",
            Ed25519PublicKey = new byte[32],
            State = TrustState.Blocked,
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });
        var transport = new FakeTransport();
        var protocolRouter = new FakeProtocolMessageRouter();
        var presenceService = new PresenceService();
        var identityManager = new IdentityManager();
        await using var worker = new TestWorker(
            NullLogger<Worker>.Instance,
            ipcListener,
            identityManager,
            trustStore,
            discoveryService,
            transport,
            protocolRouter,
            presenceService);

        await worker.StartAsync(CancellationToken.None);
        await WaitUntilAsync(() => discoveryService.StartAdvertisingCalled);

        Assert.False(discoveryService.StartDiscoveryCalled);
        Assert.Empty(transport.ConnectAttempts);

        await worker.StopAsync(CancellationToken.None);
    }

    private static async Task WaitUntilAsync(Func<bool> condition, int timeoutMs = 3000)
    {
        var startedAt = Environment.TickCount64;
        while (!condition())
        {
            if (Environment.TickCount64 - startedAt > timeoutMs)
            {
                throw new TimeoutException("Condition was not met within the allotted time.");
            }

            await Task.Delay(25);
        }
    }

    private sealed class TestWorker : Worker, IAsyncDisposable
    {
        public TestWorker(
            Microsoft.Extensions.Logging.ILogger<Worker> logger,
            IIpcListener ipcListener,
            IIdentityManager identityManager,
            ITrustStore trustStore,
            IDiscoveryService discoveryService,
            ITransport transport,
            IProtocolMessageRouter protocolMessageRouter,
            IPresenceService presenceService)
            : base(logger, ipcListener, identityManager, trustStore, discoveryService, transport, protocolMessageRouter, presenceService)
        {
        }

        public ValueTask DisposeAsync()
        {
            Dispose();
            return ValueTask.CompletedTask;
        }

        public Task RunExecuteAsync(CancellationToken cancellationToken) => ExecuteAsync(cancellationToken);
    }


    private sealed class FakeIpcListener : IIpcListener
    {
        public Task ListenAsync(CancellationToken stoppingToken) => Task.Delay(Timeout.Infinite, stoppingToken);
    }

    private sealed class DelayedFaultIpcListener(TimeSpan delay, Exception exception) : IIpcListener
    {
        public TaskCompletionSource Faulted { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);

        public async Task ListenAsync(CancellationToken stoppingToken)
        {
            await Task.Delay(delay, stoppingToken);
            Faulted.TrySetResult();
            throw exception;
        }
    }

    private sealed class FakeDiscoveryService : IDiscoveryService
    {
        public event EventHandler<PeerDiscoveredEventArgs>? PeerDiscovered
        {
            add { }
            remove { }
        }

        public bool StartAdvertisingCalled { get; private set; }
        public bool StartDiscoveryCalled { get; private set; }

        public bool StopAdvertisingCalled { get; private set; }

        public bool StopDiscoveryCalled { get; private set; }

        public void StartAdvertising(string deviceId, string minVersion, string maxVersion)
        {
            StartAdvertisingCalled = true;
        }

        public void StopAdvertising()
        {
            StopAdvertisingCalled = true;
        }

        public void StartDiscovery()
        {
            StartDiscoveryCalled = true;
        }

        public void StopDiscovery()
        {
            StopDiscoveryCalled = true;
        }
    }

    private sealed class FakeTransport : ITransport
    {
        public event EventHandler<MessageReceivedEventArgs>? MessageReceived;
        public event EventHandler<SessionStateChangedEventArgs>? SessionStateChanged;

        private readonly ConcurrentDictionary<string, bool> _activeSessions = new(StringComparer.Ordinal);

        public ConcurrentBag<SentMessage> SentMessages { get; } = [];
        public ConcurrentBag<(string Host, int Port, string? ExpectedDeviceId)> ConnectAttempts { get; } = [];
        public string ConnectedDeviceId { get; set; } = "rift-test-peer";
        public string? UnexpectedIdentityHost { get; set; }

        public Task StartListeningAsync(CancellationToken cancellationToken) => Task.Delay(Timeout.Infinite, cancellationToken);

        public async Task ConnectToPeerAsync(string host, int port, CancellationToken cancellationToken)
        {
            await ConnectToPeerWithIdentityAsync(host, port, cancellationToken);
        }

        public Task<string> ConnectToPeerWithIdentityAsync(string host, int port, CancellationToken cancellationToken, string? expectedDeviceId = null)
        {
            ConnectAttempts.Add((host, port, expectedDeviceId));
            if (string.Equals(host, UnexpectedIdentityHost, StringComparison.Ordinal))
            {
                return Task.FromException<string>(new UnexpectedPeerIdentityException(
                    host,
                    port,
                    expectedDeviceId ?? "rift-expected-peer",
                    "rift-unexpected-peer"));
            }
            _activeSessions[ConnectedDeviceId] = true;
            return Task.FromResult(ConnectedDeviceId);
        }

        public Task SendAsync(string peerDeviceId, ReadOnlyMemory<byte> frameBody, CancellationToken cancellationToken)
        {
            using var document = JsonDocument.Parse(frameBody);
            var root = document.RootElement;
            var capabilities = root.GetProperty("payload").TryGetProperty("capabilities", out var capabilitiesElement)
                ? capabilitiesElement.EnumerateArray().Select(element => element.GetString() ?? string.Empty).Where(value => value.Length > 0).ToArray()
                : [];
            SentMessages.Add(new SentMessage(
                peerDeviceId,
                root.GetProperty("type").GetString() ?? string.Empty,
                capabilities));
            return Task.CompletedTask;
        }

        public bool HasActiveSession(string peerDeviceId) =>
            _activeSessions.TryGetValue(peerDeviceId, out var active) && active;
        public bool HasProtectedSession(string peerDeviceId) => HasActiveSession(peerDeviceId);
        public void RefreshSessionAuthorization(string peerDeviceId) { }
        public PeerSessionEndpoint? GetPeerSessionEndpoint(string peerDeviceId) => null;
        public Task DisconnectPeerAsync(string peerDeviceId, CancellationToken cancellationToken)
        {
            _activeSessions.TryRemove(peerDeviceId, out _);
            return Task.CompletedTask;
        }

        public void SetActiveSession(string peerDeviceId, bool active)
        {
            if (active)
            {
                _activeSessions[peerDeviceId] = true;
            }
            else
            {
                _activeSessions.TryRemove(peerDeviceId, out _);
            }
        }

        public void EmitSessionStateChanged(string peerDeviceId, bool isOnline, IReadOnlyList<string> selectedCapabilities, bool allowsProtectedTraffic = true)
        {
            SetActiveSession(peerDeviceId, isOnline);
            SessionStateChanged?.Invoke(this, new SessionStateChangedEventArgs(peerDeviceId, isOnline, selectedCapabilities, allowsProtectedTraffic));
        }

        public void EmitMessageReceived(string peerDeviceId, ReadOnlyMemory<byte> payload)
        {
            MessageReceived?.Invoke(this, new MessageReceivedEventArgs(
                peerDeviceId,
                payload,
                new SessionPeerContext(peerDeviceId, ["clipboard.offer_fetch", "presence.basic", "operation.lifecycle", "security.event_log"], allowsProtectedTraffic: true)));
        }
    }

    private sealed class CompletingTransport : ITransport
    {
        public event EventHandler<MessageReceivedEventArgs>? MessageReceived
        {
            add { }
            remove { }
        }
        public event EventHandler<SessionStateChangedEventArgs>? SessionStateChanged
        {
            add { }
            remove { }
        }

        public Task StartListeningAsync(CancellationToken cancellationToken) => Task.CompletedTask;

        public Task ConnectToPeerAsync(string host, int port, CancellationToken cancellationToken) => Task.CompletedTask;

        public Task<string> ConnectToPeerWithIdentityAsync(string host, int port, CancellationToken cancellationToken, string? expectedDeviceId = null) =>
            Task.FromResult("rift-test-peer");

        public Task SendAsync(string peerDeviceId, ReadOnlyMemory<byte> frameBody, CancellationToken cancellationToken) => Task.CompletedTask;

        public bool HasActiveSession(string peerDeviceId) => false;
        public bool HasProtectedSession(string peerDeviceId) => false;
        public void RefreshSessionAuthorization(string peerDeviceId) { }
        public PeerSessionEndpoint? GetPeerSessionEndpoint(string peerDeviceId) => null;
        public Task DisconnectPeerAsync(string peerDeviceId, CancellationToken cancellationToken) => Task.CompletedTask;
    }

    private sealed class FakeProtocolMessageRouter : IProtocolMessageRouter
    {
        public ConcurrentBag<RoutedMessage> Messages { get; } = [];

        public Task HandleMessageAsync(SessionPeerContext session, ReadOnlyMemory<byte> payload, CancellationToken cancellationToken)
        {
            Messages.Add(new RoutedMessage(session.PeerDeviceId, Encoding.UTF8.GetString(payload.Span)));
            return Task.CompletedTask;
        }
    }

    private sealed class BlockingProtocolMessageRouter : IProtocolMessageRouter
    {
        private readonly TaskCompletionSource _firstMessageStarted = new(TaskCreationOptions.RunContinuationsAsynchronously);
        private readonly TaskCompletionSource _releaseFirstMessage = new(TaskCreationOptions.RunContinuationsAsynchronously);
        private int _startedCount;

        public List<RoutedMessage> Messages { get; } = [];
        public Task FirstMessageStarted => _firstMessageStarted.Task;
        public int StartedCount => Volatile.Read(ref _startedCount);

        public async Task HandleMessageAsync(SessionPeerContext session, ReadOnlyMemory<byte> payload, CancellationToken cancellationToken)
        {
            var started = Interlocked.Increment(ref _startedCount);
            if (started == 1)
            {
                _firstMessageStarted.TrySetResult();
                await _releaseFirstMessage.Task.WaitAsync(cancellationToken);
            }

            lock (Messages)
            {
                Messages.Add(new RoutedMessage(session.PeerDeviceId, Encoding.UTF8.GetString(payload.Span)));
            }
        }

        public void ReleaseFirstMessage() => _releaseFirstMessage.TrySetResult();
    }

    private sealed record SentMessage(string PeerDeviceId, string Type, IReadOnlyList<string> Capabilities);

    private sealed record RoutedMessage(string PeerDeviceId, string Payload);

    private sealed class FakeTrustStore : ITrustStore
    {
        public List<PeerIdentity> Peers { get; } = [];
        public int SaveCount { get; private set; }

        public void SavePeer(PeerIdentity peer)
        {
            SaveCount++;
        }

        public PeerIdentity? GetPeer(string deviceId) =>
            Peers.FirstOrDefault(peer => string.Equals(peer.DeviceId, deviceId, StringComparison.Ordinal));

        public IEnumerable<PeerIdentity> GetAllPeers() => Peers;

        public bool TryTransition(string deviceId, TrustState newState) => throw new NotImplementedException();

        public void RevokePeer(string deviceId, string revocationEvidence) => throw new NotImplementedException();
        public void DeletePeer(string deviceId) => throw new NotImplementedException();
    }

    private sealed class ListLogger<T> : ILogger<T>
    {
        public ConcurrentBag<LogEntry> Entries { get; } = [];

        public IDisposable BeginScope<TState>(TState state) where TState : notnull => NullScope.Instance;

        public bool IsEnabled(LogLevel logLevel) => true;

        public void Log<TState>(
            LogLevel logLevel,
            EventId eventId,
            TState state,
            Exception? exception,
            Func<TState, Exception?, string> formatter)
        {
            Entries.Add(new LogEntry(logLevel, formatter(state, exception), exception));
        }
    }

    private sealed record LogEntry(LogLevel LogLevel, string Message, Exception? Exception);

    private sealed class NullScope : IDisposable
    {
        public static NullScope Instance { get; } = new();

        public void Dispose()
        {
        }
    }
}
