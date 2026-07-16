using System.Security.Cryptography.X509Certificates;
using Microsoft.Extensions.Logging.Abstractions;
using Rift.Daemon.Core;
using Rift.Daemon.Core.Cryptography;
using Rift.Daemon.Core.Interfaces;

namespace Rift.Daemon.Tests.Core;

public sealed class PairingServiceTests
{
    [Fact]
    public async Task ApprovePairingAsync_KeepsPeerPendingUntilProtocolCompletion()
    {
        var trustStore = new InMemoryTrustStore();
        var identityManager = new FakeIdentityManager();
        var securityEventLog = new InMemorySecurityEventLog();
        var coordinator = new FakePairingProtocolCoordinator();
        var service = new PairingService(
            trustStore,
            identityManager,
            securityEventLog,
            coordinator,
            logger: NullLogger<PairingService>.Instance);

        var peerPublicKey = new byte[32];
        peerPublicKey[0] = 0x42;
        var deviceId = IdentityManager.DeriveDeviceId(peerPublicKey);
        trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = deviceId,
            Ed25519PublicKey = peerPublicKey,
            State = TrustState.PairingPending,
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });

        var result = await service.ApprovePairingAsync(
            deviceId,
            IdentityManager.DeriveFingerprint(peerPublicKey));

        Assert.Equal(deviceId, result.TrustedDeviceId);
        Assert.Equal(deviceId, coordinator.ApprovedDeviceId);
        Assert.Equal(TrustState.PairingPending, trustStore.GetPeer(deviceId)!.State);
        Assert.DoesNotContain(securityEventLog.Records, record =>
            record.EventType == SecurityEventTypes.PairingCompleted &&
            record.PeerDeviceId == deviceId);
    }

    private sealed class InMemoryTrustStore : ITrustStore
    {
        private readonly Dictionary<string, PeerIdentity> _peers = new(StringComparer.Ordinal);

        public void SavePeer(PeerIdentity peer) => _peers[peer.DeviceId] = peer;

        public PeerIdentity? GetPeer(string deviceId) =>
            _peers.TryGetValue(deviceId, out var peer) ? peer : null;

        public void DeletePeer(string deviceId) => _peers.Remove(deviceId);

        public IEnumerable<PeerIdentity> GetAllPeers() => _peers.Values;

        public bool TryTransition(string deviceId, TrustState newState)
        {
            if (!_peers.TryGetValue(deviceId, out var peer))
            {
                return false;
            }

            peer.State = newState;
            return true;
        }

        public void RevokePeer(string deviceId, string revocationEvidence)
        {
            if (_peers.TryGetValue(deviceId, out var peer))
            {
                peer.State = TrustState.Revoked;
                peer.RevocationEvidence = revocationEvidence;
            }
        }
    }

    private sealed class FakeIdentityManager : IIdentityManager
    {
        public void EnsureIdentityInitialized()
        {
        }

        public string GetDeviceId() => "rift-local-device";

        public byte[] GetEd25519PublicKey() => new byte[32];

        public X509Certificate2 GetTlsCertificate() => throw new NotSupportedException();

        public byte[] SignEd25519(byte[] data) => [];

        public string GetFingerprint() => "LOCAL-FINGERPRINT";

        public string GetDisplayName() => "macOS Desktop";

        public bool VerifyEd25519(byte[] publicKey, byte[] data, byte[] signature) => true;
    }

    private sealed class InMemorySecurityEventLog : ISecurityEventLog
    {
        public List<SecurityEventRecord> Records { get; } = [];

        public Task LogEventAsync(SecurityEventRecord securityEvent)
        {
            Records.Add(securityEvent);
            return Task.CompletedTask;
        }

        public Task<IReadOnlyList<SecurityEventRecord>> QueryEventsAsync(SecurityEventQuery query)
        {
            return Task.FromResult<IReadOnlyList<SecurityEventRecord>>(Records);
        }
    }

    private sealed class FakePairingProtocolCoordinator : IPairingProtocolCoordinator
    {
        public string? ApprovedDeviceId { get; private set; }

        public Task NotifyLocalPairingStartedAsync(string deviceId, CancellationToken cancellationToken = default) =>
            Task.CompletedTask;

        public Task<string> ConnectToEndpointForPairingAsync(string host, int port, CancellationToken cancellationToken = default) =>
            Task.FromResult("rift-manual-peer");

        public Task NotifyLocalPairingApprovedAsync(string deviceId, CancellationToken cancellationToken = default)
        {
            ApprovedDeviceId = deviceId;
            return Task.CompletedTask;
        }

        public Task NotifyLocalPairingRejectedAsync(string deviceId, CancellationToken cancellationToken = default) =>
            Task.CompletedTask;

        public Task NotifyLocalTrustRemovedAsync(string deviceId, string reason, CancellationToken cancellationToken = default) =>
            Task.CompletedTask;

        public Task HandleMessageAsync(string peerDeviceId, ReadOnlyMemory<byte> payload, CancellationToken cancellationToken) =>
            Task.CompletedTask;
    }
}
