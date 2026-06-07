using System.Collections.Generic;

namespace Rift.Daemon.Core.Interfaces;

public interface IDiscoveryService
{
    void StartAdvertising(string deviceId, string minVersion, string maxVersion);

    void StopAdvertising();

    void StartDiscovery();

    void StopDiscovery();
}
