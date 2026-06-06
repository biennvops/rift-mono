using System.Collections.Generic;

namespace Rift.Daemon.Windows.Core.Interfaces;

public interface IDiscoveryService
{
    /// <summary>
    /// Starts advertising this device over mDNS-SD using Makaretu.
    /// Only exposes non-sensitive device info.
    /// </summary>
    void StartAdvertising(string deviceId, int minVersion, int maxVersion);

    /// <summary>
    /// Stops advertising this device.
    /// </summary>
    void StopAdvertising();

    /// <summary>
    /// Starts scanning the local network for Rift peers.
    /// </summary>
    void StartDiscovery();

    /// <summary>
    /// Stops scanning the local network for Rift peers.
    /// </summary>
    void StopDiscovery();
}
