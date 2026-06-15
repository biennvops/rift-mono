using System;
using System.Collections.Generic;
using System.Linq;
using System.Net;
using Makaretu.Dns;
using Microsoft.Extensions.Logging;
using Rift.Daemon.Core.Interfaces;

namespace Rift.Daemon.Core.Networking;

public class DiscoveryService : IDiscoveryService, IDisposable
{
    private readonly ILogger<DiscoveryService> _logger;
    private readonly ITrustStore _trustStore;
    private readonly MulticastService _mdns;
    private ServiceDiscovery? _sd;
    private ServiceProfile? _profile;

    public int Port { get; set; } = 0;

    public DiscoveryService(ILogger<DiscoveryService> logger, ITrustStore trustStore)
    {
        _logger = logger;
        _trustStore = trustStore;
        _mdns = new MulticastService();
    }

    public void StartAdvertising(string deviceId, string minVersion, string maxVersion)
    {
        if (_sd != null) return;

        _logger.LogInformation("Starting mDNS advertisement for device {DeviceId}", deviceId);

        _mdns.Start();
        _sd = new ServiceDiscovery(_mdns);

        // Spec §4.1: Opaque random identifier regenerated on each cycle
        string instanceName = Guid.NewGuid().ToString("n").Substring(0, 16);

        _profile = new ServiceProfile(instanceName, "_rift._tcp", (ushort)Port);
        
        // Spec §4.2: TXT records
        _profile.AddProperty("minV", minVersion);
        _profile.AddProperty("maxV", maxVersion);
        
        // Note: Spec §4.2 says 'did' and 'fp' SHOULD NOT be included by default for privacy.
        // We omit them here unless explicitly needed.

        _sd.Advertise(_profile);
    }

    public void StopAdvertising()
    {
        if (_sd == null) return;

        _logger.LogInformation("Stopping mDNS advertisement");
        _sd.Unadvertise(_profile);
        _sd.Dispose();
        _sd = null;
        _profile = null;
    }

    public void StartDiscovery()
    {
        _logger.LogInformation("Starting mDNS peer discovery");
        
        if (!_mdns.IsRunning)
        {
            _mdns.Start();
        }

        if (_sd == null)
        {
            _sd = new ServiceDiscovery(_mdns);
        }

        _mdns.AnswerReceived += OnAnswerReceived;
        
        // Query for Rift services
        _mdns.SendQuery("_rift._tcp.local");
    }

    public void StopDiscovery()
    {
        _logger.LogInformation("Stopping mDNS peer discovery");
        _mdns.AnswerReceived -= OnAnswerReceived;
    }

    private void OnAnswerReceived(object? sender, MessageEventArgs e)
    {
        var response = e.Message;
        
        // Look for SRV and TXT records for _rift._tcp.local
        var srvRecords = response.Answers.OfType<SRVRecord>().Where(r => r.Name.ToString().Contains("_rift._tcp.local"));
        
        foreach (var srv in srvRecords)
        {
            // Try to find the Device ID if it was provided in the TXT record (as a hint)
            // Spec §4.2: 'did' is a non-authoritative hint.
            string? deviceId = null;
            var txtRecord = response.Answers.OfType<TXTRecord>().FirstOrDefault(r => r.Name == srv.Name);
            if (txtRecord != null)
            {
                var didEntry = txtRecord.Strings.FirstOrDefault(s => s.StartsWith("did="));
                if (didEntry != null)
                {
                    deviceId = didEntry.Substring(4);
                }
            }

            // If we don't have a deviceId hint, we can't easily track them in TrustStore by DeviceId 
            // until we connect and perform TLS handshake.
            // However, spec §4.3 says: "When a previously advertised peer's service record disappears, 
            // the implementation SHOULD mark the peer as unreachable but MUST NOT change its trust state based on discovery events alone."
            
            // For now, if we see a Rift peer, we log it. 
            // A full implementation would likely keep a 'DiscoveredPeers' list with (Address, Port, HintDeviceId).
            _logger.LogDebug("Discovered Rift peer service: {Name} at {Target}:{Port}", srv.Name, srv.Target, srv.Port);
            
            // If deviceId was hinted, we could update TrustStore to Discovered state if it's not already tracked.
            if (!string.IsNullOrEmpty(deviceId))
            {
                var existing = _trustStore.GetPeer(deviceId);
                if (existing == null)
                {
                    _trustStore.SavePeer(new PeerIdentity
                    {
                        DeviceId = deviceId,
                        State = TrustState.Discovered,
                        LastStateTransitionAt = DateTimeOffset.UtcNow
                    });
                }
            }
        }
    }

    public void Dispose()
    {
        StopAdvertising();
        StopDiscovery();
        _mdns.Stop();
        _mdns.Dispose();
    }
}
