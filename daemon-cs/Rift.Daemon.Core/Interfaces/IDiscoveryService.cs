using System.Collections.Generic;
using System.Net;

namespace Rift.Daemon.Core.Interfaces;

public sealed class PeerDiscoveredEventArgs : EventArgs
{
    public string InstanceName { get; }
    public string Host { get; }
    public int Port { get; }
    public string? MinVersion { get; }
    public string? MaxVersion { get; }
    public IPEndPoint? RemoteEndPoint { get; }

    public PeerDiscoveredEventArgs(
        string instanceName,
        string host,
        int port,
        string? minVersion,
        string? maxVersion,
        IPEndPoint? remoteEndPoint)
    {
        InstanceName = instanceName ?? throw new ArgumentNullException(nameof(instanceName));
        Host = host ?? throw new ArgumentNullException(nameof(host));
        Port = port;
        MinVersion = minVersion;
        MaxVersion = maxVersion;
        RemoteEndPoint = remoteEndPoint;
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
