using System.Collections.Concurrent;
using System.Net;
using System.Net.Sockets;
using Rift.Daemon.Core.Interfaces;

namespace Rift.Daemon.Core;

public sealed class DiscoveryCoordinator : IDiscoveryCoordinator
{
    private readonly IDiscoveryService _discoveryService;
    private readonly ITrustStore _trustStore;
    private readonly ConcurrentDictionary<string, DiscoveredPeerInfo> _discoveredPeers = new(StringComparer.Ordinal);
    private int _isDiscovering;

    public DiscoveryCoordinator(IDiscoveryService discoveryService, ITrustStore trustStore)
    {
        _discoveryService = discoveryService;
        _trustStore = trustStore;
        _discoveryService.PeerDiscovered += OnPeerDiscovered;
    }

    public DiscoveryToggleResult StartDiscovery()
    {
        _discoveryService.StartDiscovery();
        Interlocked.Exchange(ref _isDiscovering, 1);
        return new DiscoveryToggleResult { Started = true };
    }

    public DiscoveryToggleResult StopDiscovery()
    {
        _discoveryService.StopDiscovery();
        Interlocked.Exchange(ref _isDiscovering, 0);
        return new DiscoveryToggleResult { Stopped = true };
    }

    public ListDiscoveredPeersResult ListDiscoveredPeers()
    {
        var peers = _discoveredPeers.Values
            .OrderBy(peer => peer.DeviceId, StringComparer.Ordinal)
            .ToArray();

        return new ListDiscoveredPeersResult
        {
            Peers = peers,
            IsDiscovering = Volatile.Read(ref _isDiscovering) == 1
        };
    }

    public bool TryGetDiscoveredPeer(string deviceId, out DiscoveredPeerInfo? peer)
    {
        var found = _discoveredPeers.TryGetValue(deviceId, out var storedPeer);
        peer = storedPeer;
        return found;
    }

    private void OnPeerDiscovered(object? sender, PeerDiscoveredEventArgs e)
    {
        if (Volatile.Read(ref _isDiscovering) == 0)
        {
            return;
        }

        if (string.IsNullOrWhiteSpace(e.DeviceIdHint))
        {
            return;
        }

        var trustState = _trustStore.GetPeer(e.DeviceIdHint)?.State.ToString().ToLowerInvariant() ?? "discovered";
        var candidateAddress = SelectPreferredAddress(e.Host, e.RemoteEndPoint?.Address);

        _discoveredPeers.AddOrUpdate(
            e.DeviceIdHint,
            _ => new DiscoveredPeerInfo
            {
                DeviceId = e.DeviceIdHint,
                Address = candidateAddress,
                Port = e.Port,
                TrustState = trustState,
                TxtRecord = new Dictionary<string, string>(e.TxtRecord, StringComparer.Ordinal)
            },
            (_, existing) => new DiscoveredPeerInfo
            {
                DeviceId = e.DeviceIdHint,
                Address = PreferAddress(existing.Address, candidateAddress),
                Port = e.Port,
                TrustState = trustState,
                TxtRecord = new Dictionary<string, string>(e.TxtRecord, StringComparer.Ordinal)
            });
    }

    private static string SelectPreferredAddress(string host, IPAddress? remoteAddress)
    {
        var remote = remoteAddress?.ToString();
        if (string.IsNullOrWhiteSpace(remote))
        {
            return host;
        }

        return PreferAddress(host, remote);
    }

    private static string PreferAddress(string current, string candidate)
    {
        return GetAddressScore(candidate) > GetAddressScore(current) ? candidate : current;
    }

    private static int GetAddressScore(string address)
    {
        if (!IPAddress.TryParse(address, out var ipAddress))
        {
            return 0;
        }

        if (ipAddress.AddressFamily == AddressFamily.InterNetwork)
        {
            return 3;
        }

        if (ipAddress.AddressFamily == AddressFamily.InterNetworkV6)
        {
            if (ipAddress.IsIPv6LinkLocal || ipAddress.IsIPv6Multicast || ipAddress.IsIPv6SiteLocal)
            {
                // IPv6 link-local/multicast/site-local addresses are frequently unusable for outbound
                // connects without a scope ID (e.g., fe80::/10). Prefer hostnames or global IPv6
                // over these to avoid EINVAL on connect.
                return -1;
            }

            return 2;
        }

        return 0;
    }
}
