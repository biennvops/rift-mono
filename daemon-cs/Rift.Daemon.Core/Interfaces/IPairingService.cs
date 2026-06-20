namespace Rift.Daemon.Core.Interfaces;

public sealed class StartPairingResult
{
    public string Fingerprint { get; init; } = string.Empty;
    public string PeerFingerprint { get; init; } = string.Empty;
    public int ExpiresInMs { get; init; }
}

public sealed class ApprovePairingResult
{
    public string TrustedDeviceId { get; init; } = string.Empty;
    public string PersistedAt { get; init; } = string.Empty;
}

public sealed class RejectPairingResult
{
    public bool Rejected { get; init; }
}

public sealed class RevokeTrustResult
{
    public bool Revoked { get; init; }
    public string RevokedAt { get; init; } = string.Empty;
}

public sealed class UnblockPeerResult
{
    public bool Unblocked { get; init; }
}

public interface IPairingService
{
    Task<StartPairingResult> StartPairingAsync(string deviceId);

    Task<ApprovePairingResult> ApprovePairingAsync(string deviceId, string fingerprint);

    Task<RejectPairingResult> RejectPairingAsync(string deviceId);

    Task<RevokeTrustResult> RevokeTrustAsync(string deviceId, string reason);

    Task<UnblockPeerResult> UnblockPeerAsync(string deviceId);
}
