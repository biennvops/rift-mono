using Microsoft.Data.Sqlite;
using Microsoft.Extensions.Logging.Abstractions;
using Rift.Daemon.Core;
using Rift.Daemon.Core.Cryptography;
using Rift.Daemon.Core.Data;
using Rift.Daemon.Core.Interfaces;
using Rift.Daemon.Core.Networking;

namespace Rift.Daemon.Tests.Core;

/// <summary>
/// Desktop-to-desktop interop scenario: two full daemon-core stacks
/// (real TLS transport, real SQLite trust stores, real pairing coordinators)
/// pair over loopback, reconnect as trusted peers, and enforce blocking.
/// </summary>
public sealed class PairingInteropTests : IDisposable
{
    private static readonly TimeSpan ScenarioTimeout = TimeSpan.FromSeconds(20);

    private readonly PeerStack _initiator;
    private readonly PeerStack _responder;

    public PairingInteropTests()
    {
        _initiator = new PeerStack("initiator");
        _responder = new PeerStack("responder");
    }

    public void Dispose()
    {
        _initiator.Dispose();
        _responder.Dispose();
    }

    [Fact]
    public async Task DesktopPeers_PairReconnectTrustedAndEnforceBlock()
    {
        using var cancellation = new CancellationTokenSource(ScenarioTimeout);
        var token = cancellation.Token;

        var listenerTask = _responder.Transport.StartListeningAsync(token);
        var port = await _responder.WaitForListeningPortAsync(token);

        // 1. Session bootstrap between two unpaired peers.
        var responderOnline = _initiator.WaitForSessionOnline(_responder.DeviceId);
        await _initiator.Transport.ConnectToPeerWithIdentityAsync("127.0.0.1", port, token);
        await responderOnline.WaitAsync(token);

        Assert.False(_initiator.Transport.HasProtectedSession(_responder.DeviceId));
        Assert.False(_responder.Transport.HasProtectedSession(_initiator.DeviceId));
        await WaitForConditionAsync(
            () => _initiator.TrustStore.GetPeer(_responder.DeviceId)?.State == TrustState.Discovered &&
                  _responder.TrustStore.GetPeer(_initiator.DeviceId)?.State == TrustState.Discovered,
            token);

        // 2. Mutual pairing approval over the live session.
        await _initiator.Pairing.NotifyLocalPairingStartedAsync(_responder.DeviceId, token);
        await WaitForConditionAsync(
            () => _responder.TrustStore.GetPeer(_initiator.DeviceId)?.State == TrustState.PairingPending,
            token);

        await _responder.Pairing.NotifyLocalPairingApprovedAsync(_initiator.DeviceId, token);
        await WaitForConditionAsync(
            () => _initiator.TrustStore.GetPeer(_responder.DeviceId)?.State == TrustState.Trusted &&
                  _responder.TrustStore.GetPeer(_initiator.DeviceId)?.State == TrustState.Trusted,
            token);
        await WaitForConditionAsync(
            () => _initiator.Transport.HasProtectedSession(_responder.DeviceId) &&
                  _responder.Transport.HasProtectedSession(_initiator.DeviceId),
            token);

        // 3. Trusted reconnect: a fresh session is authorized immediately.
        var responderOffline = _initiator.WaitForSessionOffline(_responder.DeviceId);
        await _initiator.Transport.DisconnectPeerAsync(_responder.DeviceId, token);
        await responderOffline.WaitAsync(token);
        await WaitForConditionAsync(
            () => !_responder.Transport.HasActiveSession(_initiator.DeviceId),
            token);

        var reconnectOnline = _initiator.WaitForSessionOnline(_responder.DeviceId);
        await _initiator.Transport.ConnectToPeerWithIdentityAsync("127.0.0.1", port, token);
        var reconnectedSession = await reconnectOnline.WaitAsync(token);

        Assert.True(reconnectedSession.AllowsProtectedTraffic);
        await WaitForConditionAsync(
            () => _responder.Transport.HasProtectedSession(_initiator.DeviceId),
            token);

        // 4. Blocking terminates the session and rejects reconnects.
        Assert.True(_responder.TrustStore.TryTransition(_initiator.DeviceId, TrustState.Blocked));
        await _responder.Transport.DisconnectPeerAsync(_initiator.DeviceId, token);
        await WaitForConditionAsync(
            () => !_initiator.Transport.HasActiveSession(_responder.DeviceId),
            token);

        await Assert.ThrowsAnyAsync<Exception>(() =>
            _initiator.Transport.ConnectToPeerWithIdentityAsync("127.0.0.1", port, token));
        Assert.False(_responder.Transport.HasActiveSession(_initiator.DeviceId));

        cancellation.Cancel();
        await listenerTask;
    }

    private static async Task WaitForConditionAsync(Func<bool> condition, CancellationToken cancellationToken)
    {
        while (!condition())
        {
            await Task.Delay(20, cancellationToken);
        }
    }

    private sealed class PeerStack : IDisposable
    {
        private readonly string _databasePath;

        public PeerStack(string name)
        {
            _databasePath = Path.Combine(Path.GetTempPath(), $"rift-pairing-interop-{name}-{Guid.NewGuid():N}.db");
            var databaseContext = new DatabaseContext(_databasePath);
            databaseContext.Initialize();
            TrustStore = new SqliteTrustStore(databaseContext);
            Identity = new IdentityManager(new SqliteLocalIdentityStore(databaseContext));
            Identity.EnsureIdentityInitialized();
            Transport = new TlsTransport(
                NullLogger<TlsTransport>.Instance,
                Identity,
                TrustStore,
                securityEventLog: null,
                listenPort: 0);
            Pairing = new PairingProtocolCoordinator(
                Transport,
                new EmptyDiscoveryCoordinator(),
                TrustStore,
                Identity,
                new NoOpSecurityEventLog());
            Transport.MessageReceived += OnMessageReceived;
        }

        public SqliteTrustStore TrustStore { get; }

        public IdentityManager Identity { get; }

        public TlsTransport Transport { get; }

        public PairingProtocolCoordinator Pairing { get; }

        public string DeviceId => Identity.GetDeviceId();

        public Task<SessionStateChangedEventArgs> WaitForSessionOnline(string peerDeviceId) =>
            WaitForSessionState(peerDeviceId, online: true);

        public Task<SessionStateChangedEventArgs> WaitForSessionOffline(string peerDeviceId) =>
            WaitForSessionState(peerDeviceId, online: false);

        public async Task<int> WaitForListeningPortAsync(CancellationToken cancellationToken)
        {
            int? port;
            while ((port = Transport.ListeningPort) is null)
            {
                await Task.Delay(10, cancellationToken);
            }
            return port.Value;
        }

        public void Dispose()
        {
            Transport.MessageReceived -= OnMessageReceived;
            Pairing.Dispose();
            Transport.Dispose();
            SqliteConnection.ClearAllPools();
            if (File.Exists(_databasePath))
            {
                File.Delete(_databasePath);
            }
        }

        private Task<SessionStateChangedEventArgs> WaitForSessionState(string peerDeviceId, bool online)
        {
            var completion = new TaskCompletionSource<SessionStateChangedEventArgs>(
                TaskCreationOptions.RunContinuationsAsynchronously);
            Transport.SessionStateChanged += (_, args) =>
            {
                if (args.IsOnline == online && args.PeerDeviceId == peerDeviceId)
                {
                    completion.TrySetResult(args);
                }
            };
            return completion.Task;
        }

        private void OnMessageReceived(object? sender, MessageReceivedEventArgs args)
        {
            // Mirror the Worker's routing for the pairing subset used here.
            _ = Task.Run(() => Pairing.HandleMessageAsync(args.PeerDeviceId, args.Payload, CancellationToken.None));
        }
    }

    private sealed class EmptyDiscoveryCoordinator : IDiscoveryCoordinator
    {
        public DiscoveryToggleResult StartDiscovery() => new() { Started = false };

        public DiscoveryToggleResult StopDiscovery() => new() { Stopped = false };

        public ListDiscoveredPeersResult ListDiscoveredPeers() => new();

        public bool TryGetDiscoveredPeer(string deviceId, out DiscoveredPeerInfo? peer)
        {
            peer = null;
            return false;
        }
    }
}
