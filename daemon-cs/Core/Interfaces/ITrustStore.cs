using System.Collections.Generic;

namespace Rift.Daemon.Windows.Core.Interfaces;

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
    public string DeviceId { get; set; } = string.Empty;
    public byte[]? Ed25519PublicKey { get; set; }
    public TrustState State { get; set; }
}

public interface ITrustStore
{
    /// <summary>
    /// Saves or updates a peer in the local database.
    /// </summary>
    void SavePeer(PeerIdentity peer);

    /// <summary>
    /// Retrieves a peer by their Device ID.
    /// </summary>
    PeerIdentity? GetPeer(string deviceId);

    /// <summary>
    /// Gets all peers currently tracked by the trust store.
    /// </summary>
    IEnumerable<PeerIdentity> GetAllPeers();

    /// <summary>
    /// Updates the state of a peer tracking the state machine transition.
    /// </summary>
    void UpdatePeerState(string deviceId, TrustState newState);

    /// <summary>
    /// Rejects future connection attempts and removes key material.
    /// </summary>
    void RevokePeer(string deviceId);
}
