using System;
using System.Collections.Generic;

namespace Rift.Daemon.Core.Interfaces;

public enum TrustState
{
    Discovered,
    PairingPending,
    Trusted,
    Blocked,
    Revoked
}

public class PeerIdentity
{
    public string DeviceId { get; init; } = string.Empty;
    public byte[]? Ed25519PublicKey { get; set; }
    public TrustState State { get; set; }

    public string? EcdsaCertificateFingerprint { get; set; }
    public DateTimeOffset LastStateTransitionAt { get; set; }

    public string? RevocationEvidence { get; set; }
}

public interface ITrustStore
{
    void SavePeer(PeerIdentity peer);

    PeerIdentity? GetPeer(string deviceId);

    IEnumerable<PeerIdentity> GetAllPeers();

    bool TryTransition(string deviceId, TrustState newState);

    void RevokePeer(string deviceId, string revocationEvidence);
}
