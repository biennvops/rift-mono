using System;
using System.Collections.Generic;
using System.Linq;
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
    private bool _isMdnsRunning;

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
        if (_isMdnsRunning)
        {
            return;
        }

        _mdns.Start();
        _isMdnsRunning = true;
    }

    private void StopMdnsIfIdle()
    {
        if (_isAdvertising || _isDiscovering || !_isMdnsRunning)
        {
            return;
        }

        _mdns.Stop();
        _isMdnsRunning = false;
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

        var peerInfo = CreatePeerDiscoveredEventArgs(e);
        _logger.LogInformation(
            "Discovered Rift peer instance: {InstanceName} at {Host}:{Port}",
            peerInfo.InstanceName,
            peerInfo.Host,
            peerInfo.Port);
        PeerDiscovered?.Invoke(this, peerInfo);
    }

    private static PeerDiscoveredEventArgs CreatePeerDiscoveredEventArgs(ServiceInstanceDiscoveryEventArgs e)
    {
        var records = e.Message.Answers.Concat(e.Message.AdditionalRecords).ToArray();

        var serviceInstanceName = e.ServiceInstanceName;
        var srvRecord = records
            .OfType<SRVRecord>()
            .FirstOrDefault(record => record.Name == serviceInstanceName);

        if (srvRecord is null)
        {
            throw new InvalidOperationException($"Discovered service instance '{serviceInstanceName}' did not include an SRV record.");
        }

        var txtRecord = records
            .OfType<TXTRecord>()
            .FirstOrDefault(record => record.Name == serviceInstanceName);

        var txtProperties = ParseTxtProperties(txtRecord);
        var host = srvRecord.Target.ToString();
        var port = srvRecord.Port;

        return new PeerDiscoveredEventArgs(
            instanceName: serviceInstanceName.ToString(),
            host: host,
            port: port,
            minVersion: txtProperties.GetValueOrDefault("minV"),
            maxVersion: txtProperties.GetValueOrDefault("maxV"),
            remoteEndPoint: e.RemoteEndPoint);
    }

    private static Dictionary<string, string> ParseTxtProperties(TXTRecord? txtRecord)
    {
        var properties = new Dictionary<string, string>(StringComparer.Ordinal);
        if (txtRecord is null)
        {
            return properties;
        }

        foreach (var entry in txtRecord.Strings)
        {
            var separatorIndex = entry.IndexOf('=');
            if (separatorIndex <= 0)
            {
                continue;
            }

            var key = entry[..separatorIndex];
            var value = entry[(separatorIndex + 1)..];
            properties[key] = value;
        }

        return properties;
    }

    public void Dispose()
    {
        lock (_syncRoot)
        {
            _isAdvertising = false;
            _isDiscovering = false;
            if (_isMdnsRunning)
            {
                _mdns.Stop();
                _isMdnsRunning = false;
            }
            _serviceDiscovery.Dispose();
            _mdns.Dispose();
        }
    }
}
