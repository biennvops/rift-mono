using Rift.Daemon.Core.Interfaces;

namespace Rift.Daemon.Core;

public sealed class DaemonInfoService(
    IIdentityManager identityManager,
    ISecurityEventLog securityEventLog,
    ITrustStore trustStore,
    IDiscoveryCoordinator discoveryCoordinator,
    IPresenceService presenceService) : IDaemonInfoService
{
    private static readonly CapabilityInfo[] Capabilities =
    [
        new() { Name = "clipboard.offer_fetch", Version = 1 },
        new() { Name = "presence.basic", Version = 1 },
        new() { Name = "operation.lifecycle", Version = 1 },
        new() { Name = "security.event_log", Version = 1 }
    ];

    public DeviceInfoResult GetDeviceInfo()
    {
        return new DeviceInfoResult
        {
            DeviceId = identityManager.GetDeviceId(),
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
            .Where(peer => peer.State != TrustState.Discovered)
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

    public ListDiscoveredPeersResult ListDiscoveredPeers() => discoveryCoordinator.ListDiscoveredPeers();

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
