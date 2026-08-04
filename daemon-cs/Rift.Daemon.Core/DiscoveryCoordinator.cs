using System.Collections.Concurrent;
using System.Net;
using System.Net.Sockets;
using Rift.Daemon.Core.Interfaces;

namespace Rift.Daemon.Core;

public sealed class DiscoveryCoordinator : IDiscoveryCoordinator
{
    private sealed record ObservedEndpoint(string Address, int Port, DateTimeOffset LastSeenAt);

    private sealed record CachedDiscoveredPeer(
        string DeviceId,
        string TrustState,
        IReadOnlyDictionary<string, string> TxtRecord,
        IReadOnlyList<ObservedEndpoint> Endpoints);

    private static readonly TimeSpan DefaultDiscoveryPeerTtl = TimeSpan.FromSeconds(90);

    private readonly IDiscoveryService _discoveryService;
    private readonly ITrustStore _trustStore;
    private readonly IIdentityManager _identityManager;
    private readonly TimeProvider _timeProvider;
    private readonly TimeSpan _peerTtl;
    private readonly ConcurrentDictionary<string, CachedDiscoveredPeer> _discoveredPeers = new(StringComparer.Ordinal);
    private int _isDiscovering;

    public DiscoveryCoordinator(
        IDiscoveryService discoveryService,
        ITrustStore trustStore,
        IIdentityManager identityManager,
        TimeProvider? timeProvider = null,
        TimeSpan? peerTtl = null)
    {
        _discoveryService = discoveryService;
        _trustStore = trustStore;
        _identityManager = identityManager;
        _timeProvider = timeProvider ?? TimeProvider.System;
        _peerTtl = peerTtl ?? DefaultDiscoveryPeerTtl;
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
        _discoveredPeers.Clear();
        return new DiscoveryToggleResult { Stopped = true };
    }

    public ListDiscoveredPeersResult ListDiscoveredPeers()
    {
        PruneExpiredPeers();
        var peers = _discoveredPeers.Values
            .Select(ToPeerInfo)
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
        PruneExpiredPeers();
        var found = _discoveredPeers.TryGetValue(deviceId, out var storedPeer);
        peer = storedPeer is null ? null : ToPeerInfo(storedPeer);
        return found && peer is not null;
    }

    private void OnPeerDiscovered(object? sender, PeerDiscoveredEventArgs e)
    {
        if (Volatile.Read(ref _isDiscovering) == 0)
        {
            return;
        }

        var peerKey = !string.IsNullOrWhiteSpace(e.DeviceIdHint) ? e.DeviceIdHint : e.InstanceName;

        if (string.IsNullOrWhiteSpace(peerKey) || string.Equals(peerKey, _identityManager.GetDeviceId(), StringComparison.Ordinal))
        {
            return;
        }

        var observedAt = _timeProvider.GetUtcNow();
        var trustState = _trustStore.GetPeer(peerKey)?.State.ToString().ToLowerInvariant() ?? "discovered";
        var remoteAddress = e.RemoteEndPoint?.Address;
        var candidateEndpoints = new[] { remoteAddress?.ToString() }
            .Concat(e.ObservedAddresses.Select(address => SelectPreferredAddress(address, remoteAddress)))
            .Where(address => !string.IsNullOrWhiteSpace(address))
            .Distinct(StringComparer.Ordinal)
            .Select(address => new ObservedEndpoint(address!, e.Port, observedAt))
            .ToArray();

        if (candidateEndpoints.Length == 0)
        {
            candidateEndpoints = [new ObservedEndpoint(SelectPreferredAddress(e.Host, e.RemoteEndPoint?.Address), e.Port, observedAt)];
        }

        _discoveredPeers.AddOrUpdate(
            peerKey,
            _ => new CachedDiscoveredPeer(
                peerKey,
                trustState,
                new Dictionary<string, string>(e.TxtRecord, StringComparer.Ordinal),
                candidateEndpoints),
            (_, existing) => new CachedDiscoveredPeer(
                peerKey,
                trustState,
                new Dictionary<string, string>(e.TxtRecord, StringComparer.Ordinal),
                MergeEndpoints(existing.Endpoints, candidateEndpoints, observedAt, _peerTtl)));
    }

    private void PruneExpiredPeers()
    {
        var expiresBefore = _timeProvider.GetUtcNow() - _peerTtl;
        foreach (var entry in _discoveredPeers)
        {
            var remainingEndpoints = entry.Value.Endpoints
                .Where(endpoint => endpoint.LastSeenAt >= expiresBefore)
                .ToArray();

            if (remainingEndpoints.Length == entry.Value.Endpoints.Count)
            {
                continue;
            }

            if (remainingEndpoints.Length == 0)
            {
                _discoveredPeers.TryRemove(entry.Key, out _);
                continue;
            }

            _discoveredPeers.TryUpdate(
                entry.Key,
                entry.Value with { Endpoints = remainingEndpoints },
                entry.Value);
        }
    }

    private static IReadOnlyList<ObservedEndpoint> MergeEndpoints(
        IReadOnlyList<ObservedEndpoint> existingEndpoints,
        IReadOnlyList<ObservedEndpoint> candidateEndpoints,
        DateTimeOffset observedAt,
        TimeSpan peerTtl)
    {
        var expiresBefore = observedAt - peerTtl;
        var merged = new List<ObservedEndpoint>(existingEndpoints.Count + candidateEndpoints.Count);
        var remainingCandidates = new HashSet<(string Address, int Port)>(
            candidateEndpoints.Select(endpoint => (endpoint.Address, endpoint.Port)));

        foreach (var endpoint in existingEndpoints)
        {
            if (endpoint.LastSeenAt < expiresBefore)
            {
                continue;
            }

            if (remainingCandidates.Remove((endpoint.Address, endpoint.Port)))
            {
                merged.Add(candidateEndpoints.First(candidate =>
                    string.Equals(candidate.Address, endpoint.Address, StringComparison.Ordinal) &&
                    candidate.Port == endpoint.Port));
                continue;
            }

            merged.Add(endpoint);
        }

        foreach (var candidateEndpoint in candidateEndpoints)
        {
            if (remainingCandidates.Remove((candidateEndpoint.Address, candidateEndpoint.Port)))
            {
                merged.Add(candidateEndpoint);
            }
        }

        return merged
            .OrderByDescending(endpoint => GetEndpointScore(endpoint.Address))
            .ToArray();
    }

    private static DiscoveredPeerInfo ToPeerInfo(CachedDiscoveredPeer peer)
    {
        var orderedEndpoints = peer.Endpoints
            .OrderByDescending(endpoint => GetEndpointScore(endpoint.Address))
            .ToArray();

        var primary = orderedEndpoints[0];
        return new DiscoveredPeerInfo
        {
            DeviceId = peer.TxtRecord.TryGetValue("did", out var did) && !string.IsNullOrWhiteSpace(did) ? did : null,
            InstanceId = peer.DeviceId, // peer.DeviceId is actually the fallback instance handle
            Address = primary.Address,
            Port = primary.Port,
            TrustState = peer.TrustState,
            TxtRecord = peer.TxtRecord,
            ObservedEndpoints = orderedEndpoints
                .Select(endpoint => new DiscoveredPeerEndpoint
                {
                    Address = endpoint.Address,
                    Port = endpoint.Port
                })
                .ToArray()
        };
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
        if (IPAddress.TryParse(current, out var currentIp) &&
            IPAddress.TryParse(candidate, out var candidateIp) &&
            currentIp.IsIPv6LinkLocal &&
            currentIp.ScopeId == 0 &&
            candidateIp.IsIPv6LinkLocal &&
            candidateIp.ScopeId != 0)
        {
            return candidate;
        }

        return GetEndpointScore(candidate) > GetEndpointScore(current) ? candidate : current;
    }

    private static int GetEndpointScore(string address)
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
