namespace Rift.Daemon.Windows.Interfaces;

public enum PeerTrustState
{
    Discovered,
    PairingPending,
    Trusted,
    Blocked,
    Revoked
}

public interface ITrustStore
{
    Task<PeerTrustState?> GetTrustStateAsync(string deviceId);
    Task UpdateTrustAsync(string deviceId, PeerTrustState state);
}
