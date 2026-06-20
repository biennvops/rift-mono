namespace Rift.Daemon.Core.Interfaces;

public sealed record PeerPresenceInfo
{
    public string DeviceId { get; init; } = string.Empty;
    public string Status { get; init; } = "offline";
    public string? LastSeenAt { get; init; }
    public IReadOnlyList<string> Capabilities { get; init; } = [];
}

public interface IPresenceService
{
    void ObservePeerMessage(string deviceId);

    void UpdatePeerPresence(string deviceId, string status, string? lastSeenAt, IReadOnlyList<string> capabilities);

    void MarkPeerOffline(string deviceId);

    PeerPresenceInfo? GetPeerPresence(string deviceId);
}
