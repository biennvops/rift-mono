using System;
using System.Linq;
using Makaretu.Dns;
using Rift.Daemon.Core.Interfaces;

namespace Rift.Daemon.Core.Services;

public class MakaretuDiscoveryService : IDiscoveryService, IDisposable
{
    private MulticastService? _mdns;
    private ServiceDiscovery? _discovery;
    private ServiceProfile? _profile;

    public void StartAdvertising(string deviceId, string minVersion, string maxVersion)
    {
        EnsureInitialized();

        _profile = new ServiceProfile(deviceId, "_rift._tcp", 35142); // Default port for now, can be configurable
        _profile.AddProperty("minVersion", minVersion);
        _profile.AddProperty("maxVersion", maxVersion);

        _discovery!.Advertise(_profile);
    }

    public void StopAdvertising()
    {
        if (_profile != null && _discovery != null)
        {
            _discovery.Unadvertise(_profile);
            _profile = null;
        }
    }

    public void StartDiscovery()
    {
        EnsureInitialized();
        _mdns!.QueryServiceInstances("_rift._tcp");
        _discovery!.ServiceInstanceDiscovered += Discovery_ServiceInstanceDiscovered;
    }

    private void Discovery_ServiceInstanceDiscovered(object? sender, ServiceInstanceDiscoveryEventArgs e)
    {
        // SessionBootstrap will handle mapping these events to the state machine
    }

    public void StopDiscovery()
    {
        if (_discovery != null)
        {
            _discovery.ServiceInstanceDiscovered -= Discovery_ServiceInstanceDiscovered;
        }
    }

    private void EnsureInitialized()
    {
        if (_mdns == null)
        {
            _mdns = new MulticastService();
            _mdns.Start();
            _discovery = new ServiceDiscovery(_mdns);
        }
    }

    public void Dispose()
    {
        StopAdvertising();
        StopDiscovery();
        
        if (_discovery != null)
        {
            _discovery.Dispose();
            _discovery = null;
        }
        
        if (_mdns != null)
        {
            _mdns.Stop();
            _mdns.Dispose();
            _mdns = null;
        }
    }
}
