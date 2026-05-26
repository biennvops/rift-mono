using Rift.Daemon.Windows.Models;

namespace Rift.Daemon.Windows.Interfaces;

public interface IDiscoveryService
{
    void StartAdvertising(Capability[] capabilities);
    void StartBrowsing();
}
