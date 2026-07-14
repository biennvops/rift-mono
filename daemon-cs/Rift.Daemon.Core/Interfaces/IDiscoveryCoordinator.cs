namespace Rift.Daemon.Core.Interfaces;

public sealed class DiscoveredPeerEndpoint
{
    public string Address { get; init; } = string.Empty;
    public int Port { get; init; }
}

public sealed class DiscoveredPeerInfo
{
    [System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull)]
    public string? DeviceId { get; init; }
    [System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull)]
    public string? DisplayName { get; init; }
    public string Platform { get; init; } = "unknown";
    public string InstanceId { get; init; } = string.Empty;
    public string Address { get; init; } = string.Empty;
    public int Port { get; init; }
    public string TrustState { get; init; } = string.Empty;
    public IReadOnlyDictionary<string, string> TxtRecord { get; init; } = new Dictionary<string, string>();
    public IReadOnlyList<DiscoveredPeerEndpoint> ObservedEndpoints { get; init; } = [];
}

public sealed class ListDiscoveredPeersResult
{
    public IReadOnlyList<DiscoveredPeerInfo> Peers { get; init; } = [];
    public bool IsDiscovering { get; init; }
}

public sealed class DiscoveryToggleResult
{
    public bool Started { get; init; }
    public bool Stopped { get; init; }
}

public interface IDiscoveryCoordinator
{
    DiscoveryToggleResult StartDiscovery();

    DiscoveryToggleResult StopDiscovery();

    ListDiscoveredPeersResult ListDiscoveredPeers();

    bool TryGetDiscoveredPeer(string deviceId, out DiscoveredPeerInfo? peer);
}
