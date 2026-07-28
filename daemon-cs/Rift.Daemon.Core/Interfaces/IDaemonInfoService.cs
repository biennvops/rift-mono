namespace Rift.Daemon.Core.Interfaces;

public sealed class CapabilityInfo
{
    public string Name { get; init; } = string.Empty;
    public int Version { get; init; }
}

public sealed class DeviceInfoResult
{
    public string DeviceId { get; init; } = string.Empty;
    public string DisplayName { get; init; } = string.Empty;
    public string Platform { get; init; } = "unknown";
    public string Fingerprint { get; init; } = string.Empty;
    public string ImplementationId { get; init; } = string.Empty;
    public string ProtocolVersion { get; init; } = string.Empty;
    public string? IdentityProtectionBackend { get; init; }
    public IReadOnlyList<CapabilityInfo> Capabilities { get; init; } = [];
}

public static class DaemonCapabilities
{
    public static readonly CapabilityInfo ClipboardOfferFetch = new() { Name = "clipboard.offer_fetch", Version = 1 };
    public static readonly CapabilityInfo FileTransfer = new() { Name = "file.transfer", Version = 2 };
    public static readonly CapabilityInfo MediaPlayback = new() { Name = "media.playback", Version = 1 };
    public static readonly CapabilityInfo NotificationSync = new() { Name = "notification.sync", Version = 1 };
    public static readonly CapabilityInfo PresenceBasic = new() { Name = "presence.basic", Version = 1 };
    public static readonly CapabilityInfo OperationLifecycle = new() { Name = "operation.lifecycle", Version = 1 };
    public static readonly CapabilityInfo SecurityEventLog = new() { Name = "security.event_log", Version = 1 };
}

public sealed class QueryEventLogResult
{
    public IReadOnlyList<SecurityEventRecord> Events { get; init; } = [];
    public int Total { get; init; }
}

public sealed class TrustedPeerInfo
{
    public string DeviceId { get; init; } = string.Empty;
    public string? DisplayName { get; init; }
    public string Platform { get; init; } = "unknown";
    public string TrustState { get; init; } = string.Empty;
    public string? PairedAt { get; init; }
    public string? LastSeenAt { get; init; }
    public string Presence { get; init; } = "offline";
    public IReadOnlyList<string> Capabilities { get; init; } = [];
}

public sealed class ListTrustedPeersResult
{
    public IReadOnlyList<TrustedPeerInfo> Peers { get; init; } = [];
}

public sealed class GetPeerPresenceResult
{
    public string DeviceId { get; init; } = string.Empty;
    public string Status { get; init; } = "offline";
    public string? LastSeenAt { get; init; }
    public IReadOnlyList<string> Capabilities { get; init; } = [];
}

public interface IDaemonInfoService
{
    DeviceInfoResult GetDeviceInfo();

    Task<QueryEventLogResult> QueryEventLogAsync(SecurityEventQuery query);

    ListTrustedPeersResult ListTrustedPeers();

    ListDiscoveredPeersResult ListDiscoveredPeers();

    GetPeerPresenceResult GetPeerPresence(string deviceId);
}
