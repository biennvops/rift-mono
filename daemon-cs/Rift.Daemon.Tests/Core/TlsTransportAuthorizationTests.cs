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
        Assert.NotEmpty(storedPeer.EcdsaCertificateFingerprint);
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
