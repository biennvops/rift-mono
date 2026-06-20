using System.Collections.Concurrent;
using Rift.Daemon.Core.Interfaces;

namespace Rift.Daemon.Core;

public sealed class PresenceService : IPresenceService
{
    private readonly ConcurrentDictionary<string, PeerPresenceInfo> _presence = new(StringComparer.Ordinal);

    public void ObservePeerMessage(string deviceId)
    {
        _presence.AddOrUpdate(
            deviceId,
            _ => new PeerPresenceInfo
            {
                DeviceId = deviceId,
                Status = "online",
                LastSeenAt = DateTimeOffset.UtcNow.ToString("O"),
                Capabilities = []
            },
            (_, existing) => existing with
            {
                Status = "online",
                LastSeenAt = DateTimeOffset.UtcNow.ToString("O")
            });
    }

    public void UpdatePeerPresence(string deviceId, string status, string? lastSeenAt, IReadOnlyList<string> capabilities)
    {
        _presence[deviceId] = new PeerPresenceInfo
        {
            DeviceId = deviceId,
            Status = status,
            LastSeenAt = lastSeenAt ?? DateTimeOffset.UtcNow.ToString("O"),
            Capabilities = capabilities
        };
    }

    public void MarkPeerOffline(string deviceId)
    {
        _presence.AddOrUpdate(
            deviceId,
            _ => new PeerPresenceInfo
            {
                DeviceId = deviceId,
                Status = "offline",
                LastSeenAt = DateTimeOffset.UtcNow.ToString("O"),
                Capabilities = []
            },
            (_, existing) => existing with
            {
                Status = "offline",
                LastSeenAt = DateTimeOffset.UtcNow.ToString("O")
            });
    }

    public PeerPresenceInfo? GetPeerPresence(string deviceId)
    {
        return _presence.TryGetValue(deviceId, out var info) ? info : null;
    }
}
