using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;
using Rift.Daemon.Core.Cryptography;
using Rift.Daemon.Core.Interfaces;
using StreamJsonRpc;

namespace Rift.Daemon.Core;

public sealed class PairingService : IPairingService
{
    private const int PairingExpiryMs = 120000;

    private readonly ITrustStore _trustStore;
    private readonly IIdentityManager _identityManager;
    private readonly ISecurityEventLog _securityEventLog;
    private readonly IPairingProtocolCoordinator? _pairingProtocolCoordinator;
    private readonly ILogger<PairingService> _logger;

    public PairingService(
        ITrustStore trustStore,
        IIdentityManager identityManager,
        ISecurityEventLog securityEventLog,
        IPairingProtocolCoordinator? pairingProtocolCoordinator = null,
        ILogger<PairingService>? logger = null)
    {
        _trustStore = trustStore;
        _identityManager = identityManager;
        _securityEventLog = securityEventLog;
        _pairingProtocolCoordinator = pairingProtocolCoordinator;
        _logger = logger ?? NullLogger<PairingService>.Instance;
    }

    public StartPairingResult StartPairing(string deviceId)
    {
        var peer = GetExistingPeer(deviceId);
        EnsurePeerHasPublicKey(peer);

        if (peer.State is TrustState.Blocked or TrustState.Revoked)
        {
            throw CreateRpcException(-32004, "Peer is blocked or revoked.");
        }

        if (peer.State is not (TrustState.Discovered or TrustState.PairingPending))
        {
            throw CreateRpcException(-32008, $"Cannot start pairing from state '{peer.State}'.");
        }

        if (peer.State == TrustState.Discovered && !_trustStore.TryTransition(deviceId, TrustState.PairingPending))
        {
            throw CreateRpcException(-32008, "Failed to transition peer into pairing_pending.");
        }

        _pairingProtocolCoordinator?.NotifyLocalPairingStarted(deviceId);
        LogEvent(SecurityEventTypes.PairingAttempted, deviceId, SecurityEventOutcome.Success, null);

        return new StartPairingResult
        {
            Fingerprint = _identityManager.GetFingerprint(),
            PeerFingerprint = IdentityManager.DeriveFingerprint(peer.Ed25519PublicKey!),
            ExpiresInMs = PairingExpiryMs
        };
    }

    public ApprovePairingResult ApprovePairing(string deviceId, string fingerprint)
    {
        var peer = GetExistingPeer(deviceId);
        EnsurePeerHasPublicKey(peer);

        if (peer.State != TrustState.PairingPending)
        {
            throw CreateRpcException(-32009, "No pending pairing exists for the requested peer.");
        }

        var expectedFingerprint = IdentityManager.DeriveFingerprint(peer.Ed25519PublicKey!);
        if (!string.Equals(expectedFingerprint, fingerprint, StringComparison.Ordinal))
        {
            throw CreateRpcException(-32005, "Fingerprint mismatch.");
        }

        if (!_trustStore.TryTransition(deviceId, TrustState.Trusted))
        {
            throw CreateRpcException(-32008, "Failed to persist trusted state.");
        }

        var persistedAt = DateTimeOffset.UtcNow;
        _pairingProtocolCoordinator?.NotifyLocalPairingApproved(deviceId);
        LogEvent(SecurityEventTypes.PairingCompleted, deviceId, SecurityEventOutcome.Success, null);

        return new ApprovePairingResult
        {
            TrustedDeviceId = deviceId,
            PersistedAt = persistedAt.ToString("O")
        };
    }

    public RejectPairingResult RejectPairing(string deviceId)
    {
        var peer = GetExistingPeer(deviceId);
        if (peer.State != TrustState.PairingPending)
        {
            throw CreateRpcException(-32008, "Peer is not in pairing_pending state.");
        }

        if (!_trustStore.TryTransition(deviceId, TrustState.Discovered))
        {
            throw CreateRpcException(-32008, "Failed to reject pairing.");
        }

        _pairingProtocolCoordinator?.NotifyLocalPairingRejected(deviceId);
        LogEvent(SecurityEventTypes.PairingRejected, deviceId, SecurityEventOutcome.Success, null);
        return new RejectPairingResult { Rejected = true };
    }

    public RevokeTrustResult RevokeTrust(string deviceId, string reason)
    {
        _ = GetExistingPeer(deviceId);
        _trustStore.RevokePeer(deviceId, reason);

        var revokedAt = DateTimeOffset.UtcNow;
        LogEvent(SecurityEventTypes.TrustRevoked, deviceId, SecurityEventOutcome.Success, reason);
        return new RevokeTrustResult
        {
            Revoked = true,
            RevokedAt = revokedAt.ToString("O")
        };
    }

    public UnblockPeerResult UnblockPeer(string deviceId)
    {
        var peer = GetExistingPeer(deviceId);
        if (peer.State != TrustState.Blocked)
        {
            throw CreateRpcException(-32008, "Peer is not in blocked state.");
        }

        if (!_trustStore.TryTransition(deviceId, TrustState.Discovered))
        {
            throw CreateRpcException(-32008, "Failed to unblock peer.");
        }

        LogEvent(SecurityEventTypes.TrustTransitioned, deviceId, SecurityEventOutcome.Success, null);
        return new UnblockPeerResult { Unblocked = true };
    }

    private static LocalRpcException CreateRpcException(int errorCode, string message)
    {
        return new LocalRpcException(message)
        {
            ErrorCode = errorCode
        };
    }

    private PeerIdentity GetExistingPeer(string deviceId)
    {
        var peer = _trustStore.GetPeer(deviceId);
        if (peer is null)
        {
            throw CreateRpcException(-32009, $"Peer '{deviceId}' was not found.");
        }

        return peer;
    }

    private static void EnsurePeerHasPublicKey(PeerIdentity peer)
    {
        if (peer.Ed25519PublicKey is null || peer.Ed25519PublicKey.Length == 0)
        {
            throw CreateRpcException(-32005, $"Peer '{peer.DeviceId}' does not have an authenticated Ed25519 identity.");
        }
    }

    private void LogEvent(string eventType, string deviceId, SecurityEventOutcome outcome, string? failureReason)
    {
        _logger.LogInformation("Security event {EventType} for peer {DeviceId}.", eventType, deviceId);
        _securityEventLog.LogEventAsync(new SecurityEventRecord
        {
            EventType = eventType,
            Severity = outcome == SecurityEventOutcome.Success ? SecurityEventSeverity.Info : SecurityEventSeverity.Warning,
            LocalDeviceId = _identityManager.GetDeviceId(),
            PeerDeviceId = deviceId,
            Outcome = outcome,
            FailureReason = failureReason
        }).GetAwaiter().GetResult();
    }
}
