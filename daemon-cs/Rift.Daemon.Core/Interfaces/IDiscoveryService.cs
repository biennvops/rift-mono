using System.Collections.Generic;

namespace Rift.Daemon.Core.Interfaces;

public sealed class PeerDiscoveredEventArgs : EventArgs
{
    public string InstanceName { get; }

    public PeerDiscoveredEventArgs(string instanceName)
    {
        InstanceName = instanceName ?? throw new ArgumentNullException(nameof(instanceName));
    }
}

public interface IDiscoveryService
{
    /// <summary>
    /// Raised when mDNS discovery finds a Rift peer service instance.
    /// </summary>
    event EventHandler<PeerDiscoveredEventArgs> PeerDiscovered;

    /// <summary>
    /// Starts advertising this device over mDNS-SD using Makaretu.
    /// Only exposes non-sensitive device info.
    /// </summary>
    void StartAdvertising(string deviceId, string minVersion, string maxVersion);

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
