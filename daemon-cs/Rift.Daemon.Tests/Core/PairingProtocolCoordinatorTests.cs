using System.Text;
using System.Text.Json;
using System.Reflection;
using Microsoft.Data.Sqlite;
using Microsoft.Extensions.Logging.Abstractions;
using Rift.Daemon.Core;
using Rift.Daemon.Core.Cryptography;
using Rift.Daemon.Core.Data;
using Rift.Daemon.Core.Interfaces;

namespace Rift.Daemon.Tests.Core;

public sealed class PairingProtocolCoordinatorTests : IDisposable
{
    private static readonly TimeSpan PairingTimeout = TimeSpan.FromMinutes(2);
    private readonly string _databasePath;
    private readonly DatabaseContext _databaseContext;
    private readonly SqliteTrustStore _trustStore;
    private readonly SqliteSecurityEventLog _securityEventLog;
    private readonly IdentityManager _identityManager;
    private readonly FakeTransport _transport;
    private readonly FakeDiscoveryService _discoveryService;
    private readonly DiscoveryCoordinator _discoveryCoordinator;
    private readonly FakeTimeProvider _timeProvider;
    private readonly PairingProtocolCoordinator _coordinator;

    public PairingProtocolCoordinatorTests()
    {
        _databasePath = Path.Combine(Path.GetTempPath(), $"rift-pairing-protocol-{Guid.NewGuid():N}.db");
        _databaseContext = new DatabaseContext(_databasePath);
        _databaseContext.Initialize();
        _trustStore = new SqliteTrustStore(_databaseContext);
        _securityEventLog = new SqliteSecurityEventLog(_databaseContext);
        _identityManager = new IdentityManager(new SqliteLocalIdentityStore(_databaseContext));
        _transport = new FakeTransport();
        _discoveryService = new FakeDiscoveryService();
        _discoveryCoordinator = new DiscoveryCoordinator(_discoveryService, _trustStore);
        _timeProvider = new FakeTimeProvider(DateTimeOffset.UtcNow);
        _coordinator = new PairingProtocolCoordinator(
            _transport,
            _discoveryCoordinator,
            _trustStore,
            _identityManager,
            _securityEventLog,
            NullLogger<PairingProtocolCoordinator>.Instance,
            _timeProvider);
    }

    [Fact]
    public async Task NotifyLocalPairingStarted_ConnectsAndSendsPairingStart()
    {
        _discoveryCoordinator.StartDiscovery();
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer-start",
            Ed25519PublicKey = new byte[32],
            State = TrustState.Discovered,
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });
        _discoveryService.EmitPeerDiscovered(new PeerDiscoveredEventArgs(
            deviceIdHint: "rift-peer-start",
            instanceName: "inst-1",
            host: "192.168.1.50",
            port: 9140,
            minVersion: "0.1-draft",
            maxVersion: "0.1-draft",
            txtRecord: new Dictionary<string, string> { ["did"] = "rift-peer-start" },
            remoteEndPoint: null));

        await _coordinator.NotifyLocalPairingStartedAsync("rift-peer-start");

        Assert.Contains(_transport.ConnectionAttempts, attempt => attempt.Host == "192.168.1.50" && attempt.Port == 9140);
        Assert.Contains(_transport.SentMessages, sent => sent.PeerDeviceId == "rift-peer-start" && sent.Type == "pairing.start");
    }

    [Fact]
    public async Task HandleMessageAsync_PairingStart_TransitionsPeerToPairingPending()
    {
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer-inbound",
            Ed25519PublicKey = new byte[32],
            State = TrustState.Discovered,
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });

        await _coordinator.HandleMessageAsync("rift-peer-inbound", CreateEnvelope("rift-peer-inbound", "pairing.start", new { expiresInMs = 120000 }), CancellationToken.None);

        var peer = _trustStore.GetPeer("rift-peer-inbound");
        Assert.Equal(TrustState.PairingPending, peer!.State);
    }

    [Fact]
    public async Task HandleMessageAsync_PairingComplete_WithLocalApproval_TransitionsTrusted()
    {
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer-complete",
            Ed25519PublicKey = new byte[32],
            State = TrustState.PairingPending,
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });

        await _coordinator.NotifyLocalPairingApprovedAsync("rift-peer-complete");
        await _coordinator.HandleMessageAsync("rift-peer-complete", CreateEnvelope("rift-peer-complete", "pairing.approve", new
        {
            approvedAt = DateTimeOffset.UtcNow.ToString("O")
        }), CancellationToken.None);
        await _coordinator.HandleMessageAsync("rift-peer-complete", CreateEnvelope("rift-peer-complete", "pairing.complete", new
        {
            trustedDeviceId = "rift-peer-complete",
            persistedAt = DateTimeOffset.UtcNow.ToString("O")
        }), CancellationToken.None);

        var peer = _trustStore.GetPeer("rift-peer-complete");
        Assert.Equal(TrustState.Trusted, peer!.State);
    }

    [Fact]
    public async Task NotifyLocalPairingApproved_DoesNotSendPairingCompleteUntilRemoteApproveArrives()
    {
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer-consent",
            Ed25519PublicKey = new byte[32],
            State = TrustState.PairingPending,
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });

        await _coordinator.NotifyLocalPairingApprovedAsync("rift-peer-consent");

        Assert.Contains(_transport.SentMessages, sent => sent.PeerDeviceId == "rift-peer-consent" && sent.Type == "pairing.approve");
        Assert.DoesNotContain(_transport.SentMessages, sent => sent.PeerDeviceId == "rift-peer-consent" && sent.Type == "pairing.complete");

        await _coordinator.HandleMessageAsync("rift-peer-consent", CreateEnvelope("rift-peer-consent", "pairing.approve", new
        {
            approvedAt = DateTimeOffset.UtcNow.ToString("O")
        }), CancellationToken.None);

        Assert.Contains(_transport.SentMessages, sent => sent.PeerDeviceId == "rift-peer-consent" && sent.Type == "pairing.complete");
    }

    [Fact]
    public async Task HandleMessageAsync_PairingComplete_WithoutRemoteApprove_DoesNotTrustPeer()
    {
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer-one-sided",
            Ed25519PublicKey = new byte[32],
            State = TrustState.PairingPending,
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });

        await _coordinator.NotifyLocalPairingApprovedAsync("rift-peer-one-sided");
        await _coordinator.HandleMessageAsync("rift-peer-one-sided", CreateEnvelope("rift-peer-one-sided", "pairing.complete", new
        {
            trustedDeviceId = "rift-peer-one-sided",
            persistedAt = DateTimeOffset.UtcNow.ToString("O")
        }), CancellationToken.None);

        var peer = _trustStore.GetPeer("rift-peer-one-sided");
        Assert.Equal(TrustState.PairingPending, peer!.State);
    }

    [Fact]
    public async Task HandleMessageAsync_PairingComplete_FromUnknownPeer_DoesNotCreateGhostSession()
    {
        Assert.Equal(0, GetPairingStateCount());

        await _coordinator.HandleMessageAsync("rift-peer-ghost", CreateEnvelope("rift-peer-ghost", "pairing.complete", new
        {
            trustedDeviceId = "rift-peer-ghost",
            persistedAt = DateTimeOffset.UtcNow.ToString("O")
        }), CancellationToken.None);

        Assert.Equal(0, GetPairingStateCount());
        Assert.Null(_trustStore.GetPeer("rift-peer-ghost"));
    }

    [Fact]
    public async Task HandleMessageAsync_PairingComplete_WithoutLocalApproval_DoesNotTrustPeer()
    {
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer-no-local-approval",
            Ed25519PublicKey = new byte[32],
            State = TrustState.PairingPending,
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });

        await _coordinator.HandleMessageAsync("rift-peer-no-local-approval", CreateEnvelope("rift-peer-no-local-approval", "pairing.approve", new
        {
            approvedAt = DateTimeOffset.UtcNow.ToString("O")
        }), CancellationToken.None);
        await _coordinator.HandleMessageAsync("rift-peer-no-local-approval", CreateEnvelope("rift-peer-no-local-approval", "pairing.complete", new
        {
            trustedDeviceId = "rift-peer-no-local-approval",
            persistedAt = DateTimeOffset.UtcNow.ToString("O")
        }), CancellationToken.None);

        var peer = _trustStore.GetPeer("rift-peer-no-local-approval");
        Assert.Equal(TrustState.PairingPending, peer!.State);
    }

    [Fact]
    public async Task HandleMessageAsync_PairingComplete_WithMismatchedTrustedDeviceId_DoesNotTrustPeer()
    {
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer-mismatch",
            Ed25519PublicKey = new byte[32],
            State = TrustState.PairingPending,
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });

        await _coordinator.NotifyLocalPairingApprovedAsync("rift-peer-mismatch");
        await _coordinator.HandleMessageAsync("rift-peer-mismatch", CreateEnvelope("rift-peer-mismatch", "pairing.approve", new
        {
            approvedAt = DateTimeOffset.UtcNow.ToString("O")
        }), CancellationToken.None);
        await _coordinator.HandleMessageAsync("rift-peer-mismatch", CreateEnvelope("rift-peer-mismatch", "pairing.complete", new
        {
            trustedDeviceId = "rift-other-device",
            persistedAt = DateTimeOffset.UtcNow.ToString("O")
        }), CancellationToken.None);

        var peer = _trustStore.GetPeer("rift-peer-mismatch");
        var authFailures = await _securityEventLog.QueryEventsAsync(new SecurityEventQuery
        {
            EventTypes = [SecurityEventTypes.AuthFailed],
            PeerDeviceId = "rift-peer-mismatch",
            Limit = 10
        });

        Assert.Equal(TrustState.PairingPending, peer!.State);
        Assert.Contains(authFailures, evt => evt.FailureReason == "AuthenticationFailed");
    }

    [Fact]
    public async Task HandleMessageAsync_PairingReject_TransitionsPeerToDiscovered()
    {
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer-rejected",
            Ed25519PublicKey = new byte[32],
            State = TrustState.PairingPending,
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });

        await _coordinator.NotifyLocalPairingApprovedAsync("rift-peer-rejected");
        await _coordinator.HandleMessageAsync("rift-peer-rejected", CreateEnvelope("rift-peer-rejected", "pairing.reject", new
        {
            failureReason = "PeerRejected",
            message = "rejected"
        }), CancellationToken.None);

        var peer = _trustStore.GetPeer("rift-peer-rejected");
        var events = await _securityEventLog.QueryEventsAsync(new SecurityEventQuery
        {
            EventTypes = [SecurityEventTypes.PairingRejected],
            PeerDeviceId = "rift-peer-rejected",
            Limit = 10
        });

        Assert.Equal(TrustState.Discovered, peer!.State);
        Assert.Contains(events, evt => evt.FailureReason == "PeerRejected");
    }

    [Fact]
    public async Task HandleMessageAsync_AfterPairingExpiry_PrunesSessionAndResetsPeerState()
    {
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer-expired",
            Ed25519PublicKey = new byte[32],
            State = TrustState.PairingPending,
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });

        await _coordinator.NotifyLocalPairingApprovedAsync("rift-peer-expired");
        _timeProvider.Advance(PairingTimeout.Add(TimeSpan.FromSeconds(1)));

        await _coordinator.HandleMessageAsync("rift-peer-expired", CreateEnvelope("rift-peer-expired", "pairing.approve", new
        {
            approvedAt = _timeProvider.GetUtcNow().ToString("O")
        }), CancellationToken.None);

        var peer = _trustStore.GetPeer("rift-peer-expired");
        var events = await _securityEventLog.QueryEventsAsync(new SecurityEventQuery
        {
            EventTypes = [SecurityEventTypes.PairingRejected],
            PeerDeviceId = "rift-peer-expired",
            Limit = 10
        });

        Assert.Equal(TrustState.Discovered, peer!.State);
        Assert.DoesNotContain(_transport.SentMessages, sent => sent.PeerDeviceId == "rift-peer-expired" && sent.Type == "pairing.complete");
        Assert.Contains(events, evt => evt.FailureReason == "Timeout");
    }

    [Fact]
    public async Task NotifyLocalPairingStarted_AfterPriorExpiry_RefreshesSession()
    {
        _discoveryCoordinator.StartDiscovery();
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer-refresh",
            Ed25519PublicKey = new byte[32],
            State = TrustState.Discovered,
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });
        _discoveryService.EmitPeerDiscovered(new PeerDiscoveredEventArgs(
            deviceIdHint: "rift-peer-refresh",
            instanceName: "inst-refresh",
            host: "192.168.1.51",
            port: 9140,
            minVersion: "0.1-draft",
            maxVersion: "0.1-draft",
            txtRecord: new Dictionary<string, string> { ["did"] = "rift-peer-refresh" },
            remoteEndPoint: null));

        await _coordinator.NotifyLocalPairingStartedAsync("rift-peer-refresh");
        _timeProvider.Advance(PairingTimeout.Add(TimeSpan.FromSeconds(1)));
        await _coordinator.NotifyLocalPairingStartedAsync("rift-peer-refresh");
        await _coordinator.HandleMessageAsync("rift-peer-refresh", CreateEnvelope("rift-peer-refresh", "pairing.start", new { expiresInMs = 120000 }), CancellationToken.None);

        Assert.Equal(2, _transport.SentMessages.Count(sent => sent.PeerDeviceId == "rift-peer-refresh" && sent.Type == "pairing.start"));
    }

    public void Dispose()
    {
        SqliteConnection.ClearAllPools();
        if (File.Exists(_databasePath))
        {
            File.Delete(_databasePath);
        }
    }

    private int GetPairingStateCount()
    {
        var field = typeof(PairingProtocolCoordinator).GetField("_pairingStates", BindingFlags.Instance | BindingFlags.NonPublic);
        Assert.NotNull(field);

        var states = field!.GetValue(_coordinator) as System.Collections.IDictionary;
        Assert.NotNull(states);

        return states!.Count;
    }

    private static ReadOnlyMemory<byte> CreateEnvelope(string sourceDeviceId, string type, object payload)
    {
        var bytes = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(new
        {
            rift = "0.1-draft",
            type,
            messageId = Guid.NewGuid().ToString("D"),
            sourceDeviceId,
            payload
        }));
        return bytes;
    }

    private sealed class FakeDiscoveryService : IDiscoveryService
    {
        public event EventHandler<PeerDiscoveredEventArgs>? PeerDiscovered;

        public void StartAdvertising(string deviceId, string minVersion, string maxVersion) { }

        public void StopAdvertising() { }

        public void StartDiscovery() { }

        public void StopDiscovery() { }

        public void EmitPeerDiscovered(PeerDiscoveredEventArgs args) => PeerDiscovered?.Invoke(this, args);
    }

    private sealed class FakeTransport : ITransport
    {
        public event EventHandler<MessageReceivedEventArgs>? MessageReceived;
        public event EventHandler<SessionStateChangedEventArgs>? SessionStateChanged;

        public List<(string Host, int Port)> ConnectionAttempts { get; } = [];

        public List<(string PeerDeviceId, string Type)> SentMessages { get; } = [];

        public Task StartListeningAsync(CancellationToken cancellationToken) => Task.CompletedTask;

        public Task ConnectToPeerAsync(string host, int port, CancellationToken cancellationToken)
        {
            ConnectionAttempts.Add((host, port));
            return Task.CompletedTask;
        }

        public Task SendAsync(string peerDeviceId, ReadOnlyMemory<byte> frameBody, CancellationToken cancellationToken)
        {
            using var document = JsonDocument.Parse(frameBody);
            var type = document.RootElement.GetProperty("type").GetString() ?? string.Empty;
            SentMessages.Add((peerDeviceId, type));
            return Task.CompletedTask;
        }

        public Task DisconnectPeerAsync(string peerDeviceId, CancellationToken cancellationToken) => Task.CompletedTask;
    }

    private sealed class FakeTimeProvider(DateTimeOffset utcNow) : TimeProvider
    {
        private DateTimeOffset _utcNow = utcNow;

        public override DateTimeOffset GetUtcNow() => _utcNow;

        public void Advance(TimeSpan delta) => _utcNow = _utcNow.Add(delta);
    }
}
