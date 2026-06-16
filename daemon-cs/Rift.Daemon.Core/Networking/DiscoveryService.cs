using System;
using Makaretu.Dns;
using Microsoft.Extensions.Logging;
using Rift.Daemon.Core.Interfaces;

namespace Rift.Daemon.Core.Networking;

public sealed class DiscoveryService : IDiscoveryService, IDisposable
{
    private readonly ILogger<DiscoveryService> _logger;
    private readonly MulticastService _mdns;
    private readonly ServiceDiscovery _serviceDiscovery;
    private readonly object _syncRoot = new();
    private ServiceProfile? _profile;
    private bool _isAdvertising;
    private bool _isDiscovering;

    public event EventHandler<PeerDiscoveredEventArgs>? PeerDiscovered;

    public DiscoveryService(ILogger<DiscoveryService> logger)
    {
        _logger = logger;
        _mdns = new MulticastService();
        _serviceDiscovery = new ServiceDiscovery(_mdns);

        _serviceDiscovery.ServiceInstanceDiscovered += OnServiceInstanceDiscovered;
    }

    public void StartAdvertising(string deviceId, string minVersion, string maxVersion)
    {
        lock (_syncRoot)
        {
            if (_profile != null)
            {
                _logger.LogWarning("Advertising is already started.");
                return;
            }

            // spec §4.1: The service instance name MUST be unique.
            // Implementations SHOULD use an opaque random identifier.
            var instanceName = Guid.NewGuid().ToString("N");

            _profile = new ServiceProfile(instanceName, "_rift._tcp", RiftNetworkDefaults.DefaultPort);

            // spec §4.2: Required TXT records
            _profile.AddProperty("minV", minVersion);
            _profile.AddProperty("maxV", maxVersion);

            _serviceDiscovery.Advertise(_profile);
            StartMdnsIfNeeded();
            _isAdvertising = true;

            _logger.LogInformation("Started mDNS advertising for _rift._tcp.local. (Instance: {Instance})", instanceName);
        }
    }

    public void StopAdvertising()
    {
        lock (_syncRoot)
        {
            if (_profile != null)
            {
                _serviceDiscovery.Unadvertise(_profile);
                _profile = null;
                _isAdvertising = false;
                StopMdnsIfIdle();
                _logger.LogInformation("Stopped mDNS advertising.");
            }
        }
    }

    public void StartDiscovery()
    {
        lock (_syncRoot)
        {
            if (_isDiscovering)
            {
                _logger.LogWarning("Discovery is already started.");
                return;
            }

            StartMdnsIfNeeded();
            _isDiscovering = true;

            // Query for pointers to _rift._tcp.local
            _mdns.SendQuery("_rift._tcp.local", DnsClass.IN, DnsType.PTR);

            _logger.LogInformation("Started mDNS discovery for peers.");
        }
    }

    public void StopDiscovery()
    {
        lock (_syncRoot)
        {
            if (!_isDiscovering)
            {
                _logger.LogWarning("Discovery is already stopped.");
                return;
            }

            _isDiscovering = false;
            StopMdnsIfIdle();
            _logger.LogInformation("Stopped mDNS discovery for peers.");
        }
    }

    private void StartMdnsIfNeeded()
    {
        try
        {
            _mdns.Start();
        }
        catch (InvalidOperationException)
        {
            // Already started
        }
    }

    private void StopMdnsIfIdle()
    {
        if (_isAdvertising || _isDiscovering)
        {
            return;
        }

        _mdns.Stop();
    }

    private void OnServiceInstanceDiscovered(object? sender, ServiceInstanceDiscoveryEventArgs e)
    {
        var name = e.ServiceInstanceName.ToString();

        lock (_syncRoot)
        {
            if (_profile != null && name.StartsWith(_profile.InstanceName.ToString(), StringComparison.Ordinal))
            {
                return;
            }
        }

        _logger.LogInformation("Discovered Rift peer instance: {InstanceName}", name);
        PeerDiscovered?.Invoke(this, new PeerDiscoveredEventArgs(name));
    }

    public void Dispose()
    {
        lock (_syncRoot)
        {
            _isAdvertising = false;
            _isDiscovering = false;
            _mdns.Stop();
            _serviceDiscovery.Dispose();
            _mdns.Dispose();
        }
    }
}
