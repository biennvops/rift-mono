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
    private ServiceProfile? _profile;

    public DiscoveryService(ILogger<DiscoveryService> logger)
    {
        _logger = logger;
        _mdns = new MulticastService();
        _serviceDiscovery = new ServiceDiscovery(_mdns);
        
        _serviceDiscovery.ServiceInstanceDiscovered += OnServiceInstanceDiscovered;
    }

    public void StartAdvertising(string deviceId, string minVersion, string maxVersion)
    {
        if (_profile != null)
        {
            _logger.LogWarning("Advertising is already started.");
            return;
        }

        // spec §4.1: The service instance name MUST be unique.
        // Implementations SHOULD use an opaque random identifier.
        var instanceName = Guid.NewGuid().ToString("N");
        
        // TODO: The port should ideally be dynamic or configurable, using 9140 as a placeholder for now
        _profile = new ServiceProfile(instanceName, "_rift._tcp", 9140);
        
        // spec §4.2: Required TXT records
        _profile.AddProperty("minV", minVersion);
        _profile.AddProperty("maxV", maxVersion);

        _serviceDiscovery.Advertise(_profile);
        _mdns.Start();
        
        _logger.LogInformation("Started mDNS advertising for _rift._tcp.local. (Instance: {Instance})", instanceName);
    }

    public void StopAdvertising()
    {
        if (_profile != null)
        {
            _serviceDiscovery.Unadvertise(_profile);
            _profile = null;
            _logger.LogInformation("Stopped mDNS advertising.");
        }
    }

    public void StartDiscovery()
    {
        try
        {
            _mdns.Start();
        }
        catch (InvalidOperationException)
        {
            // Already started
        }

        // Query for pointers to _rift._tcp.local
        _mdns.SendQuery("_rift._tcp.local", DnsClass.IN, DnsType.PTR);
        
        _logger.LogInformation("Started mDNS discovery for peers.");
    }

    public void StopDiscovery()
    {
        _logger.LogInformation("Stopped mDNS discovery for peers.");
    }

    private void OnServiceInstanceDiscovered(object? sender, ServiceInstanceDiscoveryEventArgs e)
    {
        // Avoid discovering ourselves based on instance name if we had stored it
        var name = e.ServiceInstanceName.ToString();
        if (_profile != null && name.StartsWith(_profile.InstanceName.ToString()))
        {
            return;
        }

        var message = e.Message;
        // The ServiceInstanceDiscoveryEventArgs typically contains the basic SRV / TXT info
        _logger.LogInformation("Discovered Rift peer instance: {InstanceName}", name);
    }

    public void Dispose()
    {
        _serviceDiscovery.Dispose();
        _mdns.Dispose();
    }
}
