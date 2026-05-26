namespace Rift.Daemon.Windows.Models;

public enum PeerTrustState
{
    Discovered,
    PairingPending,
    Trusted,
    Blocked,
    Revoked
}

public enum IntentState
{
    Created,
    Pending,
    Dispatched,
    Active,
    Done,
    Failed,
    Expired
}

public record Peer(string DeviceId, string Name, PeerTrustState TrustState);

public record Capability(string Name, int Version);

public record RiftEvent(string Type, string Source, DateTimeOffset Timestamp);

public record ClipboardOffer(string OfferId, string ContentType, long SizeBytes, string Hash);
