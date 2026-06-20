using System.Collections.Concurrent;
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
            Peers = peers
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
        _discoveredPeers[e.DeviceIdHint] = new DiscoveredPeerInfo
        {
            DeviceId = e.DeviceIdHint,
            Address = e.Host,
            Port = e.Port,
            TrustState = trustState,
            TxtRecord = new Dictionary<string, string>(e.TxtRecord, StringComparer.Ordinal)
        };
    }
}
