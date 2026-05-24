namespace Rift.Daemon.Windows.Interfaces;

public interface IDiscoveryService
{
    void StartAdvertising();
    void StartBrowsing();
}
