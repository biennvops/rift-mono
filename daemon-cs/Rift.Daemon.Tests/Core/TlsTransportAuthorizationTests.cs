using Microsoft.Data.Sqlite;
using Microsoft.Extensions.Logging.Abstractions;
using Rift.Daemon.Core.Cryptography;
using Rift.Daemon.Core.Data;
using Rift.Daemon.Core.Interfaces;
using Rift.Daemon.Core.Networking;

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

    [Theory]
    [InlineData(TrustState.Blocked)]
    [InlineData(TrustState.Revoked)]
    public async Task ValidatePeerBeforeHandshakeAsync_RejectsBlockedOrRevokedPeer(TrustState trustState)
    {
        var remoteIdentity = new IdentityManager();
        remoteIdentity.EnsureIdentityInitialized();
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = remoteIdentity.GetDeviceId(),
            Ed25519PublicKey = remoteIdentity.GetEd25519PublicKey(),
            State = trustState,
            LastStateTransitionAt = DateTimeOffset.UtcNow,
            RevocationEvidence = trustState == TrustState.Revoked ? "user-request" : null
        });

        var ex = await Assert.ThrowsAsync<UnauthorizedAccessException>(() =>
            _transport.ValidatePeerBeforeHandshakeAsync(remoteIdentity.GetTlsCertificate(), remoteIdentity.GetDeviceId()));
        var rejectionEvents = await _securityEventLog.QueryEventsAsync(new SecurityEventQuery
        {
            EventTypes = [SecurityEventTypes.ConnectionRejected],
            PeerDeviceId = remoteIdentity.GetDeviceId(),
            Limit = 10
        });

        Assert.Contains("blocked or revoked", ex.Message, StringComparison.Ordinal);
        Assert.Contains(rejectionEvents, evt => evt.FailureReason == "Unauthorized");
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
            _ => Task.CompletedTask,
            _ => Task.CompletedTask,
            () => cleanupCalls++,
            CancellationToken.None);

        Assert.Equal(0, cleanupCalls);
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
                    return true;
                },
                CancellationToken.None));

        Assert.False(persistCalled);
        Assert.False(addCalled);
        Assert.Null(_trustStore.GetPeer(remoteDeviceId));
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
}
