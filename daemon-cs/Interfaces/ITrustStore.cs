using Rift.Daemon.Windows.Models;

namespace Rift.Daemon.Windows.Interfaces;

public interface ITrustStore
{
    Task<PeerTrustState?> GetTrustStateAsync(string deviceId);
    Task UpdateTrustAsync(string deviceId, PeerTrustState state);
    Task<IEnumerable<Peer>> GetTrustedPeersAsync();
}
