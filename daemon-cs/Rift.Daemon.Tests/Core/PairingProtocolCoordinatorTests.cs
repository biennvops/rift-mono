using System.Text;
using System.Text.Json;
using System.Reflection;
using System.Net;
using System.Net.Sockets;
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
    private readonly FakeIpcNotificationService _notificationService;
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
        _discoveryCoordinator = new DiscoveryCoordinator(_discoveryService, _trustStore, _identityManager);
        _notificationService = new FakeIpcNotificationService();
        _timeProvider = new FakeTimeProvider(DateTimeOffset.UtcNow);
        _coordinator = new PairingProtocolCoordinator(
            _transport,
            _discoveryCoordinator,
            _trustStore,
            _identityManager,
            _securityEventLog,
            ipcNotificationService: _notificationService,
            logger: NullLogger<PairingProtocolCoordinator>.Instance,
            timeProvider: _timeProvider);
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
        Assert.Contains(_transport.SentMessages, sent => sent.PeerDeviceId == "rift-manual-peer" && sent.Type == "pairing.start");
    }

    [Fact]
    public async Task NotifyLocalTrustRemovedAsync_SendsTrustRemoveMessage()
    {
        await _coordinator.NotifyLocalTrustRemovedAsync("rift-peer-removed", "User removed trusted device");

        var message = Assert.Single(_transport.SentMessages);
        Assert.Equal("rift-peer-removed", message.PeerDeviceId);
        Assert.Equal("trust.remove", message.Type);
        Assert.Equal("rift-peer-removed", message.Payload.GetProperty("removedDeviceId").GetString());
        Assert.Equal("User removed trusted device", message.Payload.GetProperty("reason").GetString());
    }

    [Fact]
    public async Task NotifyLocalPairingStarted_WhenConnectFails_ThrowsHelpfulError()
    {
        _transport.ConnectException = new InvalidOperationException("tls rejected");
        _discoveryCoordinator.StartDiscovery();
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer-connect-fail",
            Ed25519PublicKey = new byte[32],
            State = TrustState.Discovered,
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });
        _discoveryService.EmitPeerDiscovered(new PeerDiscoveredEventArgs(
            deviceIdHint: "rift-peer-connect-fail",
            instanceName: "inst-connect-fail",
            host: "192.168.1.70",
            port: 9140,
            minVersion: "0.1-draft",
            maxVersion: "0.1-draft",
            txtRecord: new Dictionary<string, string> { ["did"] = "rift-peer-connect-fail" },
            remoteEndPoint: null));

        var ex = await Assert.ThrowsAsync<InvalidOperationException>(
            () => _coordinator.NotifyLocalPairingStartedAsync("rift-peer-connect-fail"));

        Assert.Contains("Failed to establish a secure session", ex.Message);
        Assert.Contains("rift-peer-connect-fail", ex.Message);
    }

    [Fact]
    public async Task HandleMessageAsync_TrustRemove_RemovesTrustedPeerAndNotifiesUi()
    {
        var peerDeviceId = "rift-peer-removed";
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = peerDeviceId,
            Ed25519PublicKey = new byte[32],
            State = TrustState.Trusted,
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });

        await _coordinator.HandleMessageAsync(peerDeviceId, CreateEnvelope(peerDeviceId, "trust.remove", new
        {
            removedDeviceId = _identityManager.GetDeviceId(),
            reason = "Peer removed this device",
            removedAt = _timeProvider.GetUtcNow().ToString("O")
        }), CancellationToken.None);

        Assert.Null(_trustStore.GetPeer(peerDeviceId));
        Assert.Contains(
            _notificationService.Notifications,
            notification => notification.Method == "rift.onTrustChanged" &&
                Equals(notification.Parameters["deviceId"], peerDeviceId) &&
                Equals(notification.Parameters["newState"], "removed"));
    }

    [Fact]
    public async Task NotifyLocalPairingStarted_ConnectionRefused_IncludesStaleEndpointHint()
    {
        _transport.ConnectException = new SocketException((int)SocketError.ConnectionRefused);
        _discoveryCoordinator.StartDiscovery();
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer-refused",
            Ed25519PublicKey = new byte[32],
            State = TrustState.Discovered,
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });
        _discoveryService.EmitPeerDiscovered(new PeerDiscoveredEventArgs(
            deviceIdHint: "rift-peer-refused",
            instanceName: "inst-refused",
            host: "192.168.1.75",
            port: 9140,
            minVersion: "0.1-draft",
            maxVersion: "0.1-draft",
            txtRecord: new Dictionary<string, string> { ["did"] = "rift-peer-refused" },
            remoteEndPoint: null));

        var ex = await Assert.ThrowsAsync<InvalidOperationException>(
            () => _coordinator.NotifyLocalPairingStartedAsync("rift-peer-refused"));

        Assert.Contains("Failed to establish a secure session with rift-peer-refused", ex.Message);
        Assert.Contains("No discovered or persisted endpoints succeeded", ex.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task NotifyLocalPairingStarted_InvalidArgument_IncludesIpv6ScopeHint()
    {
        _transport.ConnectException = new SocketException((int)SocketError.InvalidArgument);
        _discoveryCoordinator.StartDiscovery();
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer-invalid-arg",
            Ed25519PublicKey = new byte[32],
            State = TrustState.Discovered,
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });
        _discoveryService.EmitPeerDiscovered(new PeerDiscoveredEventArgs(
            deviceIdHint: "rift-peer-invalid-arg",
            instanceName: "inst-invalid-arg",
            host: "fe80::1234",
            port: 11112,
            minVersion: "0.1-draft",
            maxVersion: "0.1-draft",
            txtRecord: new Dictionary<string, string> { ["did"] = "rift-peer-invalid-arg" },
            remoteEndPoint: null));

        var ex = await Assert.ThrowsAsync<InvalidOperationException>(
            () => _coordinator.NotifyLocalPairingStartedAsync("rift-peer-invalid-arg"));

        Assert.Contains("Failed to establish a secure session with rift-peer-invalid-arg", ex.Message);
        Assert.Contains("No discovered or persisted endpoints succeeded", ex.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task NotifyLocalPairingStarted_PrefersResolvedIpOverMdnsHostname()
    {
        _discoveryCoordinator.StartDiscovery();
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer-mdns",
            Ed25519PublicKey = new byte[32],
            State = TrustState.Discovered,
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });
        _discoveryService.EmitPeerDiscovered(new PeerDiscoveredEventArgs(
            deviceIdHint: "rift-peer-mdns",
            instanceName: "inst-mdns",
            host: "Android_ABC.local",
            port: 11112,
            minVersion: "0.1-draft",
            maxVersion: "0.1-draft",
            txtRecord: new Dictionary<string, string> { ["did"] = "rift-peer-mdns" },
            remoteEndPoint: new IPEndPoint(IPAddress.Parse("192.168.2.15"), 5353)));

        await _coordinator.NotifyLocalPairingStartedAsync("rift-peer-mdns");

        Assert.Contains(
            _transport.ConnectionAttempts,
            attempt => attempt.Host == "192.168.2.15" && attempt.Port == 11112);
    }

    [Fact]
    public async Task NotifyLocalPairingStarted_PrefersIpv4PeerAddressOverEarlierIpv6Observation()
    {
        _discoveryCoordinator.StartDiscovery();
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer-ipv4-preferred",
            Ed25519PublicKey = new byte[32],
            State = TrustState.Discovered,
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });

        _discoveryService.EmitPeerDiscovered(new PeerDiscoveredEventArgs(
            deviceIdHint: "rift-peer-ipv4-preferred",
            instanceName: "inst-ipv6",
            host: "2405:4802:6a20:e490:f093:96ff:fe22:d512",
            port: 11112,
            minVersion: "0.1-draft",
            maxVersion: "0.1-draft",
            txtRecord: new Dictionary<string, string> { ["did"] = "rift-peer-ipv4-preferred" },
            remoteEndPoint: new IPEndPoint(IPAddress.Parse("2405:4802:6a20:e490:f093:96ff:fe22:d512"), 5353)));

        _discoveryService.EmitPeerDiscovered(new PeerDiscoveredEventArgs(
            deviceIdHint: "rift-peer-ipv4-preferred",
            instanceName: "inst-ipv4",
            host: "192.168.1.32",
            port: 11112,
            minVersion: "0.1-draft",
            maxVersion: "0.1-draft",
            txtRecord: new Dictionary<string, string> { ["did"] = "rift-peer-ipv4-preferred" },
            remoteEndPoint: new IPEndPoint(IPAddress.Parse("192.168.1.32"), 5353)));

        await _coordinator.NotifyLocalPairingStartedAsync("rift-peer-ipv4-preferred");

        Assert.Contains(
            _transport.ConnectionAttempts,
            attempt => attempt.Host == "192.168.1.32" && attempt.Port == 11112);
    }

    [Fact]
    public async Task NotifyLocalPairingStarted_FallsBackToSecondaryObservedEndpoint()
    {
        _discoveryCoordinator.StartDiscovery();
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peerabcdefghijklmnopqrstuvwxyz27",
            Ed25519PublicKey = new byte[32],
            State = TrustState.Discovered,
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });

        _discoveryService.EmitPeerDiscovered(new PeerDiscoveredEventArgs(
            deviceIdHint: "rift-peerabcdefghijklmnopqrstuvwxyz27",
            instanceName: "inst-primary",
            host: "192.168.1.90",
            port: 11112,
            minVersion: "0.1-draft",
            maxVersion: "0.1-draft",
            txtRecord: new Dictionary<string, string> { ["did"] = "rift-peerabcdefghijklmnopqrstuvwxyz27" },
            remoteEndPoint: new IPEndPoint(IPAddress.Parse("192.168.1.90"), 5353)));
        _timeProvider.Advance(TimeSpan.FromSeconds(1));
        _discoveryService.EmitPeerDiscovered(new PeerDiscoveredEventArgs(
            deviceIdHint: "rift-peerabcdefghijklmnopqrstuvwxyz27",
            instanceName: "inst-secondary",
            host: "192.168.1.91",
            port: 11112,
            minVersion: "0.1-draft",
            maxVersion: "0.1-draft",
            txtRecord: new Dictionary<string, string> { ["did"] = "rift-peerabcdefghijklmnopqrstuvwxyz27" },
            remoteEndPoint: new IPEndPoint(IPAddress.Parse("192.168.1.91"), 5353)));

        _transport.ConnectExceptionFactory = () =>
        {
            var currentHost = _transport.ConnectionAttempts[^1].Host;
            return currentHost == "192.168.1.90"
                ? new SocketException((int)SocketError.ConnectionRefused)
                : null;
        };

        await _coordinator.NotifyLocalPairingStartedAsync("rift-peerabcdefghijklmnopqrstuvwxyz27");

        Assert.Equal(2, _transport.ConnectionAttempts.Count);
        Assert.Equal("192.168.1.90", _transport.ConnectionAttempts[0].Host);
        Assert.Equal("192.168.1.91", _transport.ConnectionAttempts[1].Host);
        Assert.Contains(_transport.SentMessages, sent => sent.PeerDeviceId == "rift-manual-peer" && sent.Type == "pairing.start");
    }

    [Fact]
    public async Task NotifyLocalPairingStarted_FallsBackToSecondaryAddressFromSingleDiscoveryEvent()
    {
        _discoveryCoordinator.StartDiscovery();
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer-multi-address-single-event",
            Ed25519PublicKey = new byte[32],
            State = TrustState.Discovered,
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });

        _discoveryService.EmitPeerDiscovered(new PeerDiscoveredEventArgs(
            deviceIdHint: "rift-peer-multi-address-single-event",
            instanceName: "inst-multi-address-single-event",
            host: "10.252.166.1",
            port: 9140,
            minVersion: "0.1-draft",
            maxVersion: "0.1-draft",
            txtRecord: new Dictionary<string, string> { ["did"] = "rift-peer-multi-address-single-event" },
            remoteEndPoint: new IPEndPoint(IPAddress.Parse("10.252.166.1"), 5353),
            observedAddresses: ["10.252.166.1", "192.168.1.77"]));

        _transport.ConnectExceptionFactory = () =>
        {
            var currentHost = _transport.ConnectionAttempts[^1].Host;
            return currentHost == "10.252.166.1"
                ? new SocketException((int)SocketError.TimedOut)
                : null;
        };

        await _coordinator.NotifyLocalPairingStartedAsync("rift-peer-multi-address-single-event");

        Assert.Equal(2, _transport.ConnectionAttempts.Count);
        Assert.Equal("10.252.166.1", _transport.ConnectionAttempts[0].Host);
        Assert.Equal("192.168.1.77", _transport.ConnectionAttempts[1].Host);
        Assert.Contains(_transport.SentMessages, sent => sent.PeerDeviceId == "rift-manual-peer" && sent.Type == "pairing.start");
    }

    [Fact]
    public async Task NotifyLocalPairingStarted_WhenNoSessionExists_ThrowsHelpfulError()
    {
        _transport.SendException = new InvalidOperationException("No open session exists for rift-peer-no-session.");

        var ex = await Assert.ThrowsAsync<InvalidOperationException>(
            () => _coordinator.NotifyLocalPairingStartedAsync("rift-peer-no-session"));

        Assert.Contains("Failed to establish a secure session with rift-peer-no-session", ex.Message);
        Assert.Contains("No discovered or persisted endpoints succeeded", ex.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task NotifyLocalPairingStarted_WithActiveSession_SkipsOutboundReconnect()
    {
        _transport.ActiveSessions.Add("rift-peer-live");
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer-live",
            Ed25519PublicKey = new byte[32],
            State = TrustState.Discovered,
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });

        await _coordinator.NotifyLocalPairingStartedAsync("rift-peer-live");

        Assert.Empty(_transport.ConnectionAttempts);
        Assert.Contains(_transport.SentMessages, sent => sent.PeerDeviceId == "rift-peer-live" && sent.Type == "pairing.start");
    }

    [Fact]
    public async Task NotifyLocalPairingStarted_RepeatedWhileSessionIsActive_DoesNotReconnect()
    {
        _transport.ActiveSessions.Add("rift-peer-repeat");
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer-repeat",
            Ed25519PublicKey = new byte[32],
            State = TrustState.Discovered,
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });

        await _coordinator.NotifyLocalPairingStartedAsync("rift-peer-repeat");
        await _coordinator.NotifyLocalPairingStartedAsync("rift-peer-repeat");

        Assert.Empty(_transport.ConnectionAttempts);
        Assert.Equal(
            2,
            _transport.SentMessages.Count(sent =>
                sent.PeerDeviceId == "rift-peer-repeat" && sent.Type == "pairing.start"));
    }

    [Fact]
    public async Task NotifyLocalPairingStarted_ReusesSessionThatAppearsDuringInitialWaitWindow()
    {
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer-early-inbound",
            Ed25519PublicKey = new byte[32],
            State = TrustState.Discovered,
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });

        _ = Task.Run(async () =>
        {
            await Task.Delay(25);
            _transport.ActiveSessions.Add("rift-peer-early-inbound");
            _transport.RaiseSessionStateChanged("rift-peer-early-inbound", isOnline: true);
        });

        await _coordinator.NotifyLocalPairingStartedAsync("rift-peer-early-inbound");

        Assert.Empty(_transport.ConnectionAttempts);
        Assert.Contains(
            _transport.SentMessages,
            sent => sent.PeerDeviceId == "rift-peer-early-inbound" && sent.Type == "pairing.start");
    }

    [Fact]
    public async Task NotifyLocalPairingStarted_ReusesSessionThatAppearsLateWithinExtendedInitialWaitWindow()
    {
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer-late-inbound",
            Ed25519PublicKey = new byte[32],
            State = TrustState.Discovered,
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });

        _ = Task.Run(async () =>
        {
            await Task.Delay(1100);
            _transport.ActiveSessions.Add("rift-peer-late-inbound");
            _transport.RaiseSessionStateChanged("rift-peer-late-inbound", isOnline: true);
        });

        await _coordinator.NotifyLocalPairingStartedAsync("rift-peer-late-inbound");

        Assert.Empty(_transport.ConnectionAttempts);
        Assert.Contains(
            _transport.SentMessages,
            sent => sent.PeerDeviceId == "rift-peer-late-inbound" && sent.Type == "pairing.start");
    }

    [Fact]
    public async Task NotifyLocalPairingStarted_ReusesInboundSessionThatAppearsAfterOutboundFailure()
    {
        _discoveryCoordinator.StartDiscovery();
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peerabcdefghijklmnopqrstuvwxyz24",
            Ed25519PublicKey = new byte[32],
            State = TrustState.Discovered,
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });
        _discoveryService.EmitPeerDiscovered(new PeerDiscoveredEventArgs(
            deviceIdHint: "rift-peerabcdefghijklmnopqrstuvwxyz24",
            instanceName: "inst-race",
            host: "192.168.1.88",
            port: 11112,
            minVersion: "0.1-draft",
            maxVersion: "0.1-draft",
            txtRecord: new Dictionary<string, string> { ["did"] = "rift-peerabcdefghijklmnopqrstuvwxyz24" },
            remoteEndPoint: null));

        _transport.ConnectExceptionFactory = () =>
        {
            _transport.ActiveSessions.Add("rift-peerabcdefghijklmnopqrstuvwxyz24");
            _transport.RaiseSessionStateChanged("rift-peerabcdefghijklmnopqrstuvwxyz24", isOnline: true);
            return new InvalidOperationException("Peer closed connection before sending session.hello.");
        };

        await _coordinator.NotifyLocalPairingStartedAsync("rift-peerabcdefghijklmnopqrstuvwxyz24");

        Assert.Contains(_transport.SentMessages, sent => sent.PeerDeviceId == "rift-peerabcdefghijklmnopqrstuvwxyz24" && sent.Type == "pairing.start");
    }

    [Fact]
    public async Task NotifyLocalPairingStarted_RetriesOnceAfterDuplicateCloseBeforeHello()
    {
        _discoveryCoordinator.StartDiscovery();
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peerabcdefghijklmnopqrstuvwxyz25",
            Ed25519PublicKey = new byte[32],
            State = TrustState.Discovered,
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });
        _discoveryService.EmitPeerDiscovered(new PeerDiscoveredEventArgs(
            deviceIdHint: "rift-peerabcdefghijklmnopqrstuvwxyz25",
            instanceName: "inst-retry",
            host: "192.168.1.91",
            port: 11112,
            minVersion: "0.1-draft",
            maxVersion: "0.1-draft",
            txtRecord: new Dictionary<string, string> { ["did"] = "rift-peerabcdefghijklmnopqrstuvwxyz25" },
            remoteEndPoint: null));

        var attempts = 0;
        _transport.ConnectExceptionFactory = () =>
        {
            attempts++;
            if (attempts == 1)
            {
                return new InvalidOperationException("Peer closed connection before sending session.hello.");
            }

            return null;
        };

        await _coordinator.NotifyLocalPairingStartedAsync("rift-peerabcdefghijklmnopqrstuvwxyz25");

        Assert.Equal(2, _transport.ConnectionAttempts.Count);
        Assert.Contains(_transport.SentMessages, sent => sent.PeerDeviceId == "rift-manual-peer" && sent.Type == "pairing.start");
    }

    [Fact]
    public async Task NotifyLocalPairingStarted_ReusesSessionAfterDuplicateCloseBeforeRetryingOutbound()
    {
        _discoveryCoordinator.StartDiscovery();
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peerabcdefghijklmnopqrstuvwxyz23",
            Ed25519PublicKey = new byte[32],
            State = TrustState.Discovered,
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });
        _discoveryService.EmitPeerDiscovered(new PeerDiscoveredEventArgs(
            deviceIdHint: "rift-peerabcdefghijklmnopqrstuvwxyz23",
            instanceName: "inst-reuse-after-race",
            host: "192.168.1.92",
            port: 11112,
            minVersion: "0.1-draft",
            maxVersion: "0.1-draft",
            txtRecord: new Dictionary<string, string> { ["did"] = "rift-peerabcdefghijklmnopqrstuvwxyz23" },
            remoteEndPoint: null));

        var attempts = 0;
        _transport.ConnectExceptionFactory = () =>
        {
            attempts++;
            if (attempts == 1)
            {
                _ = Task.Run(async () =>
                {
                    await Task.Delay(600);
                    _transport.ActiveSessions.Add("rift-peerabcdefghijklmnopqrstuvwxyz23");
                    _transport.RaiseSessionStateChanged("rift-peerabcdefghijklmnopqrstuvwxyz23", isOnline: true);
                });
                return new InvalidOperationException("Peer closed connection before sending session.hello.");
            }

            return null;
        };

        await _coordinator.NotifyLocalPairingStartedAsync("rift-peerabcdefghijklmnopqrstuvwxyz23");

        Assert.Single(_transport.ConnectionAttempts);
        Assert.Contains(
            _transport.SentMessages,
            sent => sent.PeerDeviceId == "rift-peerabcdefghijklmnopqrstuvwxyz23" && sent.Type == "pairing.start");
    }

    [Fact]
    public async Task ConnectToEndpointForPairingAsync_RetriesOnceAfterDuplicateCloseBeforeHello()
    {
        var attempts = 0;
        _transport.ConnectExceptionFactory = () =>
        {
            attempts++;
            if (attempts == 1)
            {
                return new InvalidOperationException("Peer closed connection before sending session.hello.");
            }

            _transport.ActiveSessions.Add("rift-manual-retry");
            return null;
        };

        var resolvedDeviceId = await _coordinator.ConnectToEndpointForPairingAsync("10.53.38.200", 11112);

        Assert.Equal("rift-manual-retry", resolvedDeviceId);
        Assert.Equal(2, _transport.ConnectionAttempts.Count);
        Assert.Equal(("10.53.38.200", 11112), _transport.ConnectionAttempts[0]);
        Assert.Equal(("10.53.38.200", 11112), _transport.ConnectionAttempts[1]);
    }

    [Fact]
    public async Task NotifyLocalPairingStarted_RemoteApproveAndComplete_TransitionsTrusted()
    {
        _transport.ActiveSessions.Add("rift-peer-linux-initiator");
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer-linux-initiator",
            Ed25519PublicKey = new byte[32],
            State = TrustState.PairingPending,
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });

        await _coordinator.NotifyLocalPairingStartedAsync("rift-peer-linux-initiator");
        await _coordinator.HandleMessageAsync("rift-peer-linux-initiator", CreateEnvelope("rift-peer-linux-initiator", "pairing.approve", new
        {
            approvedAt = DateTimeOffset.UtcNow.ToString("O")
        }), CancellationToken.None);
        await _coordinator.HandleMessageAsync("rift-peer-linux-initiator", CreateEnvelope("rift-peer-linux-initiator", "pairing.complete", new
        {
            trustedDeviceId = "rift-peer-linux-initiator",
            persistedAt = DateTimeOffset.UtcNow.ToString("O")
        }), CancellationToken.None);

        var peer = _trustStore.GetPeer("rift-peer-linux-initiator");
        Assert.Equal(TrustState.Trusted, peer!.State);
        var sentComplete = Assert.Single(
            _transport.SentMessages,
            sent => sent.PeerDeviceId == "rift-peer-linux-initiator" && sent.Type == "pairing.complete");
        Assert.Equal(_identityManager.GetDeviceId(), sentComplete.Payload.GetProperty("trustedDeviceId").GetString());
    }

    [Fact]
    public async Task NotifyLocalPairingStarted_FromDiscovered_RemoteApproveAndComplete_TransitionsTrusted()
    {
        _transport.ActiveSessions.Add("rift-peer-local-start");
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer-local-start",
            Ed25519PublicKey = new byte[32],
            State = TrustState.Discovered,
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });

        await _coordinator.NotifyLocalPairingStartedAsync("rift-peer-local-start");
        await _coordinator.HandleMessageAsync("rift-peer-local-start", CreateEnvelope("rift-peer-local-start", "pairing.approve", new
        {
            approvedAt = DateTimeOffset.UtcNow.ToString("O")
        }), CancellationToken.None);
        await _coordinator.HandleMessageAsync("rift-peer-local-start", CreateEnvelope("rift-peer-local-start", "pairing.complete", new
        {
            trustedDeviceId = "rift-peer-local-start",
            persistedAt = DateTimeOffset.UtcNow.ToString("O")
        }), CancellationToken.None);

        var peer = _trustStore.GetPeer("rift-peer-local-start");
        Assert.Equal(TrustState.Trusted, peer!.State);
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
    public async Task HandleMessageAsync_PairingStart_ThenLocalApprove_SendsPairingComplete()
    {
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer-a-initiator",
            Ed25519PublicKey = new byte[32],
            State = TrustState.Discovered,
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });

        await _coordinator.HandleMessageAsync(
            "rift-peer-a-initiator",
            CreateEnvelope("rift-peer-a-initiator", "pairing.start", new { expiresInMs = 120000 }),
            CancellationToken.None);

        await _coordinator.NotifyLocalPairingApprovedAsync("rift-peer-a-initiator");

        var sentComplete = Assert.Single(
            _transport.SentMessages,
            sent => sent.PeerDeviceId == "rift-peer-a-initiator" && sent.Type == "pairing.complete");
        Assert.Equal(_identityManager.GetDeviceId(), sentComplete.Payload.GetProperty("trustedDeviceId").GetString());
    }

    [Fact]
    public async Task HandleMessageAsync_PairingStart_WhenPeerAlreadyPairingPending_StillNotifiesIncomingRequest()
    {
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer-pending-notify",
            Ed25519PublicKey = new byte[32],
            State = TrustState.PairingPending,
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });

        await _coordinator.HandleMessageAsync(
            "rift-peer-pending-notify",
            CreateEnvelope("rift-peer-pending-notify", "pairing.start", new
            {
                expiresInMs = 120000,
                displayName = "Pixel 9"
            }),
            CancellationToken.None);

        var notification = Assert.Single(
            _notificationService.Notifications,
            evt => evt.Method == "rift.onPairingRequest");
        Assert.Equal("rift-peer-pending-notify", notification.Parameters["deviceId"]);
        Assert.Equal("Pixel 9", notification.Parameters["displayName"]);
    }

    [Fact]
    public async Task HandleMessageAsync_PairingStart_TruncatesOversizedRemoteDisplayName()
    {
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer-long-name",
            Ed25519PublicKey = new byte[32],
            State = TrustState.PairingPending,
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });

        var oversizedDisplayName = new string('A', 512);

        await _coordinator.HandleMessageAsync(
            "rift-peer-long-name",
            CreateEnvelope("rift-peer-long-name", "pairing.start", new
            {
                expiresInMs = 120000,
                displayName = oversizedDisplayName
            }),
            CancellationToken.None);

        var storedPeer = _trustStore.GetPeer("rift-peer-long-name");
        Assert.NotNull(storedPeer);
        Assert.NotNull(storedPeer!.DisplayName);
        Assert.Equal(128, storedPeer.DisplayName!.Length);
        Assert.Equal(oversizedDisplayName[..128], storedPeer.DisplayName);

        var notification = Assert.Single(
            _notificationService.Notifications,
            evt => evt.Method == "rift.onPairingRequest");
        Assert.Equal(oversizedDisplayName[..128], notification.Parameters["displayName"]);
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
    public async Task SessionStateChanged_OfflineDuringPairing_RevertsPeerToDiscovered()
    {
        _transport.ActiveSessions.Add("rift-peer-disconnected");
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer-disconnected",
            Ed25519PublicKey = new byte[32],
            State = TrustState.PairingPending,
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });

        await _coordinator.NotifyLocalPairingStartedAsync("rift-peer-disconnected");

        _transport.ActiveSessions.Remove("rift-peer-disconnected");
        _transport.RaiseSessionStateChanged("rift-peer-disconnected", isOnline: false);

        await WaitForConditionAsync(() =>
            _trustStore.GetPeer("rift-peer-disconnected")?.State == TrustState.Discovered,
            attempts: 40,
            delayMs: 100);

        var events = await _securityEventLog.QueryEventsAsync(new SecurityEventQuery
        {
            EventTypes = [SecurityEventTypes.PairingRejected],
            PeerDeviceId = "rift-peer-disconnected",
            Limit = 10
        });

        Assert.Contains(events, evt => evt.FailureReason == "PeerUnreachable");
    }

    [Fact]
    public async Task SessionStateChanged_OfflineDuringPairing_PreservesPendingStateWhenReplacementSessionAppearsQuickly()
    {
        _transport.ActiveSessions.Add("rift-peer-transient-disconnect");
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer-transient-disconnect",
            Ed25519PublicKey = new byte[32],
            State = TrustState.PairingPending,
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });

        await _coordinator.NotifyLocalPairingStartedAsync("rift-peer-transient-disconnect");

        _transport.ActiveSessions.Remove("rift-peer-transient-disconnect");
        _transport.RaiseSessionStateChanged("rift-peer-transient-disconnect", isOnline: false);

        _ = Task.Run(async () =>
        {
            await Task.Delay(200);
            _transport.ActiveSessions.Add("rift-peer-transient-disconnect");
            _transport.RaiseSessionStateChanged("rift-peer-transient-disconnect", isOnline: true);
        });

        await Task.Delay(1800);

        var peer = _trustStore.GetPeer("rift-peer-transient-disconnect");
        Assert.Equal(TrustState.PairingPending, peer!.State);

        var events = await _securityEventLog.QueryEventsAsync(new SecurityEventQuery
        {
            EventTypes = [SecurityEventTypes.PairingRejected],
            PeerDeviceId = "rift-peer-transient-disconnect",
            Limit = 10
        });

        Assert.DoesNotContain(events, evt => evt.FailureReason == "PeerUnreachable");
    }

    [Fact]
    public async Task SessionStateChanged_OfflineForTrustedPeer_PreservesTrustedState()
    {
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer-trusted-disconnect",
            Ed25519PublicKey = new byte[32],
            State = TrustState.Trusted,
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });

        _transport.RaiseSessionStateChanged("rift-peer-trusted-disconnect", isOnline: false);

        await Task.Delay(50);

        var peer = _trustStore.GetPeer("rift-peer-trusted-disconnect");
        Assert.Equal(TrustState.Trusted, peer!.State);
    }

    [Fact]
    public async Task SessionStateChanged_OnlineForTrustedPeer_PersistsLatestSessionEndpoint()
    {
        _discoveryCoordinator.StartDiscovery();
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer-trusted-online",
            Ed25519PublicKey = new byte[32],
            State = TrustState.Trusted,
            LastStateTransitionAt = DateTimeOffset.UtcNow,
            TrustedEndpoints =
            [
                new TrustedPeerEndpoint
                {
                    Address = "10.53.38.101",
                    Port = 9140,
                    Source = "pairing-session",
                    LastSuccessAt = DateTimeOffset.UtcNow.AddMinutes(-5)
                }
            ]
        });
        _discoveryService.EmitPeerDiscovered(new PeerDiscoveredEventArgs(
            deviceIdHint: "rift-peer-trusted-online",
            instanceName: "inst-online",
            host: "192.168.1.125",
            port: 11112,
            minVersion: "0.1-draft",
            maxVersion: "0.1-draft",
            txtRecord: new Dictionary<string, string> { ["did"] = "rift-peer-trusted-online" },
            remoteEndPoint: null));
        _transport.SessionEndpoints["rift-peer-trusted-online"] = new PeerSessionEndpoint("192.168.1.125", 48084);

        _transport.RaiseSessionStateChanged(
            "rift-peer-trusted-online",
            isOnline: true,
            allowsProtectedTraffic: true);

        await Task.Delay(50);

        var peer = _trustStore.GetPeer("rift-peer-trusted-online");
        Assert.NotNull(peer);
        Assert.Equal("192.168.1.125", peer!.TrustedEndpoints[0].Address);
        Assert.Equal(11112, peer.TrustedEndpoints[0].Port);
        Assert.Equal("session-established", peer.TrustedEndpoints[0].Source);
        Assert.Equal("10.53.38.101", peer.TrustedEndpoints[1].Address);
    }

    [Fact]
    public async Task ConnectToEndpointForPairingAsync_ManualEndpointHint_PersistsStablePortInsteadOfEphemeralSocketPort()
    {
        _transport.ActiveSessions.Add("rift-manual-peer");
        var resolvedDeviceId = await _coordinator.ConnectToEndpointForPairingAsync("192.168.1.125", 11112);
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = resolvedDeviceId,
            Ed25519PublicKey = new byte[32],
            State = TrustState.Trusted,
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });
        _transport.SessionEndpoints[resolvedDeviceId] = new PeerSessionEndpoint("192.168.1.125", 48084);

        _transport.RaiseSessionStateChanged(
            resolvedDeviceId,
            isOnline: true,
            allowsProtectedTraffic: true);

        await Task.Delay(50);

        var peer = _trustStore.GetPeer(resolvedDeviceId);
        Assert.NotNull(peer);
        Assert.Equal("192.168.1.125", peer!.TrustedEndpoints[0].Address);
        Assert.Equal(11112, peer.TrustedEndpoints[0].Port);
        Assert.Equal("session-established", peer.TrustedEndpoints[0].Source);
    }

    [Fact]
    public async Task SessionStateChanged_OnlineWithoutProtectedTraffic_DoesNotPersistEndpoint()
    {
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer-unprotected-online",
            Ed25519PublicKey = new byte[32],
            State = TrustState.Trusted,
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });
        _transport.SessionEndpoints["rift-peer-unprotected-online"] = new PeerSessionEndpoint("10.53.38.174", 9140);

        _transport.RaiseSessionStateChanged(
            "rift-peer-unprotected-online",
            isOnline: true,
            allowsProtectedTraffic: false);

        await Task.Delay(50);

        var peer = _trustStore.GetPeer("rift-peer-unprotected-online");
        Assert.NotNull(peer);
        Assert.Empty(peer!.TrustedEndpoints);
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
    public async Task HandleMessageAsync_RemoteApproveBeforeLocalApprove_SendsPairingCompleteAfterLocalApprove()
    {
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer-remote-first",
            Ed25519PublicKey = new byte[32],
            State = TrustState.PairingPending,
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });

        await _coordinator.HandleMessageAsync("rift-peer-remote-first", CreateEnvelope("rift-peer-remote-first", "pairing.approve", new
        {
            approvedAt = DateTimeOffset.UtcNow.ToString("O")
        }), CancellationToken.None);

        Assert.DoesNotContain(
            _transport.SentMessages,
            sent => sent.PeerDeviceId == "rift-peer-remote-first" && sent.Type == "pairing.complete");

        await _coordinator.NotifyLocalPairingApprovedAsync("rift-peer-remote-first");

        Assert.Contains(
            _transport.SentMessages,
            sent => sent.PeerDeviceId == "rift-peer-remote-first" && sent.Type == "pairing.approve");
        Assert.Contains(
            _transport.SentMessages,
            sent => sent.PeerDeviceId == "rift-peer-remote-first" && sent.Type == "pairing.complete");
    }

    [Fact]
    public async Task HandleMessageAsync_PairingApprove_FromUnknownPeer_DoesNotCreateGhostSession()
    {
        Assert.Equal(0, GetPairingStateCount());

        await _coordinator.HandleMessageAsync("rift-peer-approve-ghost", CreateEnvelope("rift-peer-approve-ghost", "pairing.approve", new
        {
            approvedAt = DateTimeOffset.UtcNow.ToString("O")
        }), CancellationToken.None);

        Assert.Equal(0, GetPairingStateCount());
        Assert.Null(_trustStore.GetPeer("rift-peer-approve-ghost"));
        Assert.DoesNotContain(_transport.SentMessages, sent => sent.PeerDeviceId == "rift-peer-approve-ghost" && sent.Type == "pairing.complete");
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
            DeviceId = "rift-peerabcdefghijklmnopqrstuvwxyz26",
            Ed25519PublicKey = new byte[32],
            State = TrustState.Discovered,
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });
        _discoveryService.EmitPeerDiscovered(new PeerDiscoveredEventArgs(
            deviceIdHint: "rift-peerabcdefghijklmnopqrstuvwxyz26",
            instanceName: "inst-refresh",
            host: "192.168.1.51",
            port: 9140,
            minVersion: "0.1-draft",
            maxVersion: "0.1-draft",
            txtRecord: new Dictionary<string, string> { ["did"] = "rift-peerabcdefghijklmnopqrstuvwxyz26" },
            remoteEndPoint: null));

        await _coordinator.NotifyLocalPairingStartedAsync("rift-peerabcdefghijklmnopqrstuvwxyz26");
        _timeProvider.Advance(PairingTimeout.Add(TimeSpan.FromSeconds(1)));
        await _coordinator.NotifyLocalPairingStartedAsync("rift-peerabcdefghijklmnopqrstuvwxyz26");
        await _coordinator.HandleMessageAsync("rift-peerabcdefghijklmnopqrstuvwxyz26", CreateEnvelope("rift-peerabcdefghijklmnopqrstuvwxyz26", "pairing.start", new { expiresInMs = 120000 }), CancellationToken.None);

        Assert.Equal(2, _transport.SentMessages.Count(sent => sent.PeerDeviceId == "rift-manual-peer" && sent.Type == "pairing.start"));
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

    private static async Task WaitForConditionAsync(Func<bool> condition, int attempts = 20, int delayMs = 25)
    {
        for (var i = 0; i < attempts; i++)
        {
            if (condition())
            {
                return;
            }

            await Task.Delay(delayMs);
        }

        Assert.True(condition(), "Condition was not met within the allotted time.");
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

    private sealed class FakeIpcNotificationService : IIpcNotificationService
    {
        public List<(string Method, Dictionary<string, object?> Parameters)> Notifications { get; } = [];

        public IDisposable RegisterClient(StreamJsonRpc.JsonRpc jsonRpc) => new NoopDisposable();

        public Task NotifyAsync(string method, object parameters, CancellationToken cancellationToken = default)
        {
            var values = parameters.GetType()
                .GetProperties(BindingFlags.Instance | BindingFlags.Public)
                .ToDictionary(property => property.Name, property => property.GetValue(parameters));
            Notifications.Add((method, values));
            return Task.CompletedTask;
        }

        private sealed class NoopDisposable : IDisposable
        {
            public void Dispose()
            {
            }
        }
    }

    private sealed class FakeTransport : ITransport
    {
        public event EventHandler<MessageReceivedEventArgs>? MessageReceived
        {
            add { }
            remove { }
        }
        public event EventHandler<SessionStateChangedEventArgs>? SessionStateChanged;

        public List<(string Host, int Port)> ConnectionAttempts { get; } = [];

        public List<(string PeerDeviceId, string Type, JsonElement Payload)> SentMessages { get; } = [];

        public Exception? ConnectException { get; set; }
        public Func<Exception?>? ConnectExceptionFactory { get; set; }
        public Exception? SendException { get; set; }
        public HashSet<string> ActiveSessions { get; } = new(StringComparer.Ordinal);
        public Dictionary<string, PeerSessionEndpoint> SessionEndpoints { get; } = new(StringComparer.Ordinal);

        public Task StartListeningAsync(CancellationToken cancellationToken) => Task.CompletedTask;

        public Task ConnectToPeerAsync(string host, int port, CancellationToken cancellationToken)
        {
            ConnectionAttempts.Add((host, port));
            if (ConnectExceptionFactory is not null)
            {
                var ex = ConnectExceptionFactory();
                if (ex is not null)
                {
                    return Task.FromException(ex);
                }
            }
            if (ConnectException is not null)
            {
                return Task.FromException(ConnectException);
            }
            return Task.CompletedTask;
        }

        public async Task<string> ConnectToPeerWithIdentityAsync(string host, int port, CancellationToken cancellationToken)
        {
            await ConnectToPeerAsync(host, port, cancellationToken);
            return ActiveSessions.FirstOrDefault() ?? "rift-manual-peer";
        }

        public Task SendAsync(string peerDeviceId, ReadOnlyMemory<byte> frameBody, CancellationToken cancellationToken)
        {
            if (SendException is not null)
            {
                return Task.FromException(SendException);
            }
            using var document = JsonDocument.Parse(frameBody);
            var type = document.RootElement.GetProperty("type").GetString() ?? string.Empty;
            var payload = document.RootElement.GetProperty("payload").Clone();
            SentMessages.Add((peerDeviceId, type, payload));
            return Task.CompletedTask;
        }

        public bool HasActiveSession(string peerDeviceId) => ActiveSessions.Contains(peerDeviceId);
        public PeerSessionEndpoint? GetPeerSessionEndpoint(string peerDeviceId) =>
            SessionEndpoints.TryGetValue(peerDeviceId, out var endpoint) ? endpoint : null;
        public Task DisconnectPeerAsync(string peerDeviceId, CancellationToken cancellationToken) => Task.CompletedTask;

        public void RaiseSessionStateChanged(string peerDeviceId, bool isOnline, bool allowsProtectedTraffic = false)
        {
            SessionStateChanged?.Invoke(
                this,
                new SessionStateChangedEventArgs(peerDeviceId, isOnline, Array.Empty<string>(), allowsProtectedTraffic));
        }
    }

    private sealed class FakeTimeProvider(DateTimeOffset utcNow) : TimeProvider
    {
        private DateTimeOffset _utcNow = utcNow;

        public override DateTimeOffset GetUtcNow() => _utcNow;

        public void Advance(TimeSpan delta) => _utcNow = _utcNow.Add(delta);
    }
}
