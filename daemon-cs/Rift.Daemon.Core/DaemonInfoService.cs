using Rift.Daemon.Core.Interfaces;

namespace Rift.Daemon.Core;

public sealed class DaemonInfoService(
    IIdentityManager identityManager,
    ISecurityEventLog securityEventLog,
    ITrustStore trustStore,
    IDiscoveryCoordinator discoveryCoordinator,
    IPresenceService presenceService,
    ITransport transport) : IDaemonInfoService
{
    private static readonly CapabilityInfo[] Capabilities =
    [
        new() { Name = "clipboard.offer_fetch", Version = 1 },
        new() { Name = "file.transfer", Version = 1 },
        new() { Name = "presence.basic", Version = 1 },
        new() { Name = "operation.lifecycle", Version = 1 },
        new() { Name = "security.event_log", Version = 1 }
    ];

    public DeviceInfoResult GetDeviceInfo()
    {

        return new DeviceInfoResult
        {
            DeviceId = identityManager.GetDeviceId(),
            DisplayName = identityManager.GetDisplayName(),
            Fingerprint = identityManager.GetFingerprint(),
            ImplementationId = "riftd-cs/0.1.0",
            ProtocolVersion = "0.1-draft",
            Capabilities = Capabilities
        };
    }

    public async Task<QueryEventLogResult> QueryEventLogAsync(SecurityEventQuery query)
    {
        var events = await securityEventLog.QueryEventsAsync(query);
        return new QueryEventLogResult
        {
            Events = events,
            Total = events.Count
        };
    }

    public ListTrustedPeersResult ListTrustedPeers()
    {
        var peers = trustStore.GetAllPeers()
            .Where(peer => peer.State is not (TrustState.Discovered or TrustState.Revoked))
            .Select(peer =>
            {
                var presence = presenceService.GetPeerPresence(peer.DeviceId);
                return new TrustedPeerInfo
                {
                    DeviceId = peer.DeviceId,
                    TrustState = peer.State.ToString().ToLowerInvariant(),
                    PairedAt = peer.State == TrustState.Trusted ? peer.LastStateTransitionAt.ToString("O") : null,
                    LastSeenAt = presence?.LastSeenAt,
                    Presence = presence?.Status ?? "offline",
                    Capabilities = presence?.Capabilities ?? []
                };
            })
            .ToArray();

        return new ListTrustedPeersResult
        {
            Peers = peers
        };
    }

    public ListDiscoveredPeersResult ListDiscoveredPeers()
    {
        var activeDiscoveries = discoveryCoordinator.ListDiscoveredPeers();
        
        var discoveredFromTrustStore = trustStore.GetAllPeers()
            .Where(p => p.State == TrustState.Discovered)
            .Select(p => new { Peer = p, Endpoint = transport.GetPeerSessionEndpoint(p.DeviceId) })
            .Where(x => x.Endpoint != null)
            .Select(x => new DiscoveredPeerInfo
            {
                DeviceId = x.Peer.DeviceId,
                InstanceId = x.Peer.DeviceId,
                Address = x.Endpoint!.Address,
                Port = x.Endpoint!.Port,
                TrustState = "discovered",
                TxtRecord = new Dictionary<string, string>(),
                ObservedEndpoints = [new DiscoveredPeerEndpoint { Address = x.Endpoint!.Address, Port = x.Endpoint!.Port }]
            })
            .Where(p => !activeDiscoveries.Peers.Any(d => string.Equals(d.DeviceId, p.DeviceId, StringComparison.Ordinal)))
            .ToArray();

        if (discoveredFromTrustStore.Length == 0)
        {
            return activeDiscoveries;
        }

        return new ListDiscoveredPeersResult
        {
            Peers = activeDiscoveries.Peers.Concat(discoveredFromTrustStore).ToArray(),
            IsDiscovering = activeDiscoveries.IsDiscovering
        };
    }

    public GetPeerPresenceResult GetPeerPresence(string deviceId)
    {
        var peer = trustStore.GetPeer(deviceId);
        if (peer is null)
        {
            throw new InvalidOperationException($"Peer '{deviceId}' was not found.");
        }

        if (peer.State != TrustState.Trusted)
        {
            throw new UnauthorizedAccessException("Peer is not trusted.");
        }

        var presence = presenceService.GetPeerPresence(deviceId);
        return new GetPeerPresenceResult
        {
                DeviceId = peer.DeviceId,
            Status = presence?.Status ?? "offline",
            LastSeenAt = presence?.LastSeenAt,
            Capabilities = presence?.Capabilities ?? []
        };
    }
}
