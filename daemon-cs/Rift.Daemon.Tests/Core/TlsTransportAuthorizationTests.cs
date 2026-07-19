using Microsoft.Data.Sqlite;
using Microsoft.Extensions.Logging.Abstractions;
using Rift.Daemon.Core.Cryptography;
using Rift.Daemon.Core.Data;
using Rift.Daemon.Core.Interfaces;
using Rift.Daemon.Core.Networking;
using System.Collections.Concurrent;
using System.Net.Security;
using System.Net.Sockets;
using System.Reflection;

namespace Rift.Daemon.Tests.Core;

public sealed class TlsTransportAuthorizationTests : IDisposable
{
    private readonly string _databasePath;
    private readonly DatabaseContext _databaseContext;
    private readonly SqliteTrustStore _trustStore;
    private readonly SqliteSecurityEventLog _securityEventLog;
    private readonly IdentityManager _localIdentity;
    private readonly TlsTransport _transport;

    public TlsTransportAuthorizationTests()
    {
        _databasePath = Path.Combine(Path.GetTempPath(), $"rift-tls-authz-{Guid.NewGuid():N}.db");
        _databaseContext = new DatabaseContext(_databasePath);
        _databaseContext.Initialize();
        _trustStore = new SqliteTrustStore(_databaseContext);
        _securityEventLog = new SqliteSecurityEventLog(_databaseContext);
        _localIdentity = new IdentityManager(new SqliteLocalIdentityStore(_databaseContext));
        _transport = new TlsTransport(NullLogger<TlsTransport>.Instance, _localIdentity, _trustStore, _securityEventLog);
    }

    [Fact]
    public async Task ValidatePeerBeforeHandshakeAsync_DoesNotPersistUnknownPeer()
    {
        var remoteIdentity = new IdentityManager();
        remoteIdentity.EnsureIdentityInitialized();
        var remoteCert = remoteIdentity.GetTlsCertificate();
        var remoteDeviceId = remoteIdentity.GetDeviceId();

        await _transport.ValidatePeerBeforeHandshakeAsync(remoteCert, remoteDeviceId);

        Assert.Null(_trustStore.GetPeer(remoteDeviceId));
    }

    [Fact]
    public async Task ValidatePeerBeforeHandshakeAsync_RejectsStoredPeerWithDifferentEd25519Key()
    {
        var trustedIdentity = new IdentityManager();
        trustedIdentity.EnsureIdentityInitialized();
        var returningIdentity = new IdentityManager();
        returningIdentity.EnsureIdentityInitialized();

        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = trustedIdentity.GetDeviceId(),
            Ed25519PublicKey = trustedIdentity.GetEd25519PublicKey(),
            State = TrustState.Trusted,
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });

        var ex = await Assert.ThrowsAsync<InvalidOperationException>(() =>
            _transport.ValidatePeerBeforeHandshakeAsync(returningIdentity.GetTlsCertificate(), trustedIdentity.GetDeviceId()));
        var authFailures = await _securityEventLog.QueryEventsAsync(new SecurityEventQuery
        {
            EventTypes = [SecurityEventTypes.AuthFailed],
            PeerDeviceId = trustedIdentity.GetDeviceId(),
            Limit = 10
        });

        Assert.Contains("did not match", ex.Message, StringComparison.Ordinal);
        Assert.Contains(authFailures, evt => evt.FailureReason == "AuthenticationFailed");
    }

    [Fact]
    public async Task ValidatePeerBeforeHandshakeAsync_RejectsBlockedPeer()
    {
        var remoteIdentity = new IdentityManager();
        remoteIdentity.EnsureIdentityInitialized();
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = remoteIdentity.GetDeviceId(),
            Ed25519PublicKey = remoteIdentity.GetEd25519PublicKey(),
            State = TrustState.Blocked,
            LastStateTransitionAt = DateTimeOffset.UtcNow,
            RevocationEvidence = null
        });

        var ex = await Assert.ThrowsAsync<UnauthorizedAccessException>(() =>
            _transport.ValidatePeerBeforeHandshakeAsync(remoteIdentity.GetTlsCertificate(), remoteIdentity.GetDeviceId()));
        var rejectionEvents = await _securityEventLog.QueryEventsAsync(new SecurityEventQuery
        {
            EventTypes = [SecurityEventTypes.ConnectionRejected],
            PeerDeviceId = remoteIdentity.GetDeviceId(),
            Limit = 10
        });

        Assert.Contains("blocked", ex.Message, StringComparison.Ordinal);
        Assert.Contains(rejectionEvents, evt => evt.FailureReason == "Unauthorized");
        Assert.NotNull(_trustStore.GetPeer(remoteIdentity.GetDeviceId()));
    }

    [Fact]
    public async Task ValidatePeerBeforeHandshakeAsync_RejectsRevokedPeerAndDeletesStoredRecord()
    {
        var remoteIdentity = new IdentityManager();
        remoteIdentity.EnsureIdentityInitialized();
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = remoteIdentity.GetDeviceId(),
            Ed25519PublicKey = remoteIdentity.GetEd25519PublicKey(),
            State = TrustState.Revoked,
            LastStateTransitionAt = DateTimeOffset.UtcNow,
            RevocationEvidence = "user revoked trust"
        });

        var ex = await Assert.ThrowsAsync<UnauthorizedAccessException>(() =>
            _transport.ValidatePeerBeforeHandshakeAsync(remoteIdentity.GetTlsCertificate(), remoteIdentity.GetDeviceId()));
        var rejectionEvents = await _securityEventLog.QueryEventsAsync(new SecurityEventQuery
        {
            EventTypes = [SecurityEventTypes.ConnectionRejected],
            PeerDeviceId = remoteIdentity.GetDeviceId(),
            Limit = 10
        });

        Assert.Contains("revoked", ex.Message, StringComparison.Ordinal);
        Assert.Contains(rejectionEvents, evt => evt.FailureReason == "Unauthorized");
        Assert.Null(_trustStore.GetPeer(remoteIdentity.GetDeviceId()));
    }

    [Fact]
    public void ShouldAllowProtectedTraffic_ReturnsTrueForTrustedPeer()
    {
        const string deviceId = "rift-peer-trusted";
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = deviceId,
            Ed25519PublicKey = new byte[32],
            State = TrustState.Trusted,
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });

        Assert.True(_transport.ShouldAllowProtectedTraffic(deviceId));
    }

    [Fact]
    public void ShouldAllowProtectedTraffic_ReturnsFalseForDiscoveredPeer()
    {
        const string deviceId = "rift-peer-discovered";
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = deviceId,
            Ed25519PublicKey = new byte[32],
            State = TrustState.Discovered,
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });

        Assert.False(_transport.ShouldAllowProtectedTraffic(deviceId));
    }

    [Fact]
    public void PersistAuthorizedPeer_PersistsUnknownPeerAfterVerifiedHandshake()
    {
        var remoteIdentity = new IdentityManager();
        remoteIdentity.EnsureIdentityInitialized();
        var remoteCert = remoteIdentity.GetTlsCertificate();
        var remoteDeviceId = remoteIdentity.GetDeviceId();

        _transport.PersistAuthorizedPeer(remoteCert, remoteDeviceId);

        var storedPeer = _trustStore.GetPeer(remoteDeviceId);
        Assert.NotNull(storedPeer);
        Assert.Equal(TrustState.Discovered, storedPeer!.State);
        Assert.Equal(remoteDeviceId, storedPeer.DeviceId);
        Assert.NotNull(storedPeer.Ed25519PublicKey);
        Assert.False(string.IsNullOrWhiteSpace(storedPeer.EcdsaCertificateFingerprint));
    }

    [Fact]
    public async Task RunSessionLifetimeCoreAsync_WhenSessionEnds_RaisesOfflineEvent()
    {
        var outboundOnline = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var outboundOffline = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var cleanupCalled = false;
        const string remoteDeviceId = "rift-peer-outbound";
        var selectedCapabilities = new[] { new CapabilityDescriptor("presence.basic", 1) };

        _transport.SessionStateChanged += (_, args) =>
        {
            if (!string.Equals(args.PeerDeviceId, remoteDeviceId, StringComparison.Ordinal))
            {
                return;
            }

            if (args.IsOnline)
            {
                outboundOnline.TrySetResult();
            }
            else
            {
                outboundOffline.TrySetResult();
            }
        };

        await _transport.RunSessionLifetimeCoreAsync(
            remoteDeviceId,
            selectedCapabilities,
            allowsProtectedTraffic: true,
            async _ =>
            {
                await outboundOnline.Task;
            },
            () => cleanupCalled = true,
            CancellationToken.None);

        await WaitAsync(outboundOffline.Task, TimeSpan.FromSeconds(5));

        Assert.True(cleanupCalled);
    }

    [Fact]
    public async Task RunSessionLifetimeCoreAsync_StaleCleanupDoesNotRaiseOfflineEvent()
    {
        const string remoteDeviceId = "rift-peer-replaced";
        var states = new List<bool>();
        _transport.SessionStateChanged += (_, args) =>
        {
            if (string.Equals(args.PeerDeviceId, remoteDeviceId, StringComparison.Ordinal))
            {
                states.Add(args.IsOnline);
            }
        };

        await _transport.RunSessionLifetimeCoreAsync(
            remoteDeviceId,
            [new CapabilityDescriptor("presence.basic", 1)],
            allowsProtectedTraffic: true,
            _ => Task.CompletedTask,
            () => false,
            CancellationToken.None);

        Assert.Equal([true], states);
    }

    [Fact]
    public async Task RunInboundSessionCoreAsync_WhenHandshakeFails_CleansUpSession()
    {
        var cleanupCalls = 0;

        await _transport.RunInboundSessionCoreAsync(
            "rift-peer-inbound-failure",
            _ => throw new InvalidOperationException("handshake failed"),
            _ => Task.CompletedTask,
            () => cleanupCalls++,
            CancellationToken.None);

        Assert.Equal(1, cleanupCalls);
    }

    [Fact]
    public async Task RunInboundSessionCoreAsync_WhenLifetimeManaged_DoesNotDoubleCleanup()
    {
        var cleanupCalls = 0;

        await _transport.RunInboundSessionCoreAsync(
            "rift-peer-inbound-success",
            _ => Task.FromResult(TlsTransport.SessionRegistrationResult.RegisteredNew),
            _ => Task.CompletedTask,
            () => cleanupCalls++,
            CancellationToken.None);

        Assert.Equal(0, cleanupCalls);
    }

    [Fact]
    public async Task RefreshSessionAuthorization_WhenPeerBecomesTrusted_EnablesProtectedTraffic()
    {
        const string remoteDeviceId = "rift-peer-refresh-auth";
        var onlineEvents = new List<SessionStateChangedEventArgs>();

        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = remoteDeviceId,
            Ed25519PublicKey = new byte[32],
            State = TrustState.PairingPending,
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });

        _transport.SessionStateChanged += (_, args) =>
        {
            if (string.Equals(args.PeerDeviceId, remoteDeviceId, StringComparison.Ordinal) && args.IsOnline)
            {
                onlineEvents.Add(args);
            }
        };

        RegisterAuthenticatedSession(remoteDeviceId, allowsProtectedTraffic: false, ["presence.basic"]);

        Assert.False(_transport.HasProtectedSession(remoteDeviceId));

        Assert.True(_trustStore.TryTransition(remoteDeviceId, TrustState.Trusted));
        _transport.RefreshSessionAuthorization(remoteDeviceId);

        Assert.True(_transport.HasProtectedSession(remoteDeviceId));
        Assert.Single(onlineEvents);
        Assert.True(onlineEvents[^1].AllowsProtectedTraffic);
    }

    [Fact]
    public async Task CompleteInboundHandshakeAndRegistrationAsync_HandshakeFailurePreventsPersistence()
    {
        var remoteIdentity = new IdentityManager();
        remoteIdentity.EnsureIdentityInitialized();
        var remoteCert = remoteIdentity.GetTlsCertificate();
        var remoteDeviceId = remoteIdentity.GetDeviceId();
        var persistCalled = false;
        var addCalled = false;

        await Assert.ThrowsAsync<InvalidOperationException>(() =>
            _transport.CompleteInboundHandshakeAndRegistrationAsync(
                remoteCert,
                remoteDeviceId,
                _ => throw new InvalidOperationException("handshake failed"),
                () => persistCalled = true,
                () =>
                {
                    addCalled = true;
                    return TlsTransport.SessionRegistrationResult.RegisteredNew;
                },
                CancellationToken.None));

        Assert.False(persistCalled);
        Assert.False(addCalled);
        Assert.Null(_trustStore.GetPeer(remoteDeviceId));
    }

    [Fact]
    public void RegisterOrReuseSession_DuplicateAuthenticatedSession_ReusesExistingSession()
    {
        const string deviceId = "rift-peer-duplicate-auth";
        RegisterAuthenticatedSession(deviceId, allowsProtectedTraffic: true, ["file.transfer"]);
        var candidate = CreateAuthenticatedSession(deviceId, allowsProtectedTraffic: true, ["file.transfer"]);

        var method = typeof(TlsTransport).GetMethod("RegisterOrReuseSession", BindingFlags.Instance | BindingFlags.NonPublic);
        Assert.NotNull(method);

        var result = (TlsTransport.SessionRegistrationResult)method!.Invoke(_transport, [deviceId, candidate])!;

        Assert.Equal(TlsTransport.SessionRegistrationResult.ReusedExisting, result);
        Assert.True(_transport.HasActiveSession(deviceId));
        Assert.True(_transport.HasProtectedSession(deviceId));
    }

    [Fact]
    public void RemoveSessionIfCurrent_StaleSessionCleanupPreservesReplacement()
    {
        const string deviceId = "rift-peer-reconnected";
        var current = CreateAuthenticatedSession(deviceId, allowsProtectedTraffic: true, ["file.transfer"]);
        var stale = CreateAuthenticatedSession(deviceId, allowsProtectedTraffic: true, ["file.transfer"]);
        RegisterSession(deviceId, current);

        var method = typeof(TlsTransport).GetMethod("RemoveSessionIfCurrent", BindingFlags.Instance | BindingFlags.NonPublic);
        Assert.NotNull(method);

        method!.Invoke(_transport, [deviceId, stale]);

        Assert.True(_transport.HasProtectedSession(deviceId));

        method.Invoke(_transport, [deviceId, current]);

        Assert.False(_transport.HasActiveSession(deviceId));
    }

    public void Dispose()
    {
        SqliteConnection.ClearAllPools();
        if (File.Exists(_databasePath))
        {
            File.Delete(_databasePath);
        }
    }

    private static async Task WaitAsync(Task task, TimeSpan timeout)
    {
        var completedTask = await Task.WhenAny(task, Task.Delay(timeout));
        if (!ReferenceEquals(completedTask, task))
        {
            throw new TimeoutException("Condition was not met within the allotted time.");
        }

        await task;
    }

    private static async Task WaitForConditionAsync(Func<bool> condition, TimeSpan timeout)
    {
        var deadline = DateTimeOffset.UtcNow + timeout;
        while (DateTimeOffset.UtcNow < deadline)
        {
            if (condition())
            {
                return;
            }

            await Task.Delay(25);
        }

        Assert.True(condition(), "Condition was not met within the allotted time.");
    }

    private void RegisterAuthenticatedSession(string deviceId, bool allowsProtectedTraffic, IReadOnlyList<string> selectedCapabilities)
    {
        var session = CreateAuthenticatedSession(deviceId, allowsProtectedTraffic, selectedCapabilities);
        RegisterSession(deviceId, session);
    }

    private void RegisterSession(string deviceId, object session)
    {
        var sessionsField = typeof(TlsTransport).GetField("_sessions", BindingFlags.Instance | BindingFlags.NonPublic);
        Assert.NotNull(sessionsField);
        var sessions = sessionsField!.GetValue(_transport)!;
        var tryAdd = sessions.GetType().GetMethod("TryAdd");
        Assert.NotNull(tryAdd);
        var added = (bool)tryAdd!.Invoke(sessions, [deviceId, session])!;
        Assert.True(added);
    }

    private static object CreateAuthenticatedSession(string deviceId, bool allowsProtectedTraffic, IReadOnlyList<string> selectedCapabilities)
    {
        var activeSessionType = typeof(TlsTransport).GetNestedType("ActiveSession", BindingFlags.NonPublic);
        Assert.NotNull(activeSessionType);

        var constructor = activeSessionType!.GetConstructor(
            BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic,
            binder: null,
            [typeof(SslStream), typeof(TcpClient), typeof(string), typeof(bool)],
            modifiers: null);
        Assert.NotNull(constructor);

        using var baseStream = new MemoryStream();
        var sslStream = new SslStream(baseStream, leaveInnerStreamOpen: false);
        var tcpClient = new TcpClient();
        var session = constructor!.Invoke([sslStream, tcpClient, deviceId, true]);

        activeSessionType.GetProperty("IsAuthenticated")!.SetValue(session, true);
        activeSessionType.GetProperty("SelectedCapabilities")!.SetValue(
            session,
            selectedCapabilities.Select(capability => new CapabilityDescriptor(capability, 1)).ToArray());
        activeSessionType.GetProperty("AllowsProtectedTraffic")!.SetValue(session, allowsProtectedTraffic);
        activeSessionType.GetProperty("PeerContext")!.SetValue(
            session,
            new SessionPeerContext(deviceId, selectedCapabilities, allowsProtectedTraffic));
        return session;
    }
}
