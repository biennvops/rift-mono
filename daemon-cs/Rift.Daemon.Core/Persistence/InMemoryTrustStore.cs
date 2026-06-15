using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using Rift.Daemon.Core.Interfaces;

namespace Rift.Daemon.Core.Persistence;

public class InMemoryTrustStore : ITrustStore
{
    private readonly ConcurrentDictionary<string, PeerIdentity> _peers = new();

    public void SavePeer(PeerIdentity peer)
    {
        _peers[peer.DeviceId] = peer;
    }

    public PeerIdentity? GetPeer(string deviceId)
    {
        _peers.TryGetValue(deviceId, out var peer);
        return peer;
    }

    public IEnumerable<PeerIdentity> GetAllPeers()
    {
        return _peers.Values;
    }

    public bool TryTransition(string deviceId, TrustState newState)
    {
        if (!_peers.TryGetValue(deviceId, out var peer)) return false;
        
        // Simple state machine validation
        bool valid = (peer.State, newState) switch
        {
            (TrustState.Discovered, TrustState.PairingPending) => true,
            (TrustState.PairingPending, TrustState.Trusted) => true,
            (TrustState.PairingPending, TrustState.Discovered) => true,
            (TrustState.Trusted, TrustState.Blocked) => true,
            (TrustState.Trusted, TrustState.Revoked) => true,
            (TrustState.Blocked, TrustState.Discovered) => true,
            (TrustState.Revoked, TrustState.Discovered) => true,
            _ => false
        };

        if (valid)
        {
            peer.State = newState;
            peer.LastStateTransitionAt = DateTimeOffset.UtcNow;
            return true;
        }

        return false;
    }

    public void RevokePeer(string deviceId, string revocationEvidence)
    {
        if (_peers.TryGetValue(deviceId, out var peer))
        {
            peer.State = TrustState.Revoked;
            peer.RevocationEvidence = revocationEvidence;
            peer.LastStateTransitionAt = DateTimeOffset.UtcNow;
        }
    }
}
