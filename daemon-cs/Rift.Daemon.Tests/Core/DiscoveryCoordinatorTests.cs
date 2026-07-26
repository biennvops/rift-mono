using System.Net;
using Microsoft.Data.Sqlite;
using Rift.Daemon.Core;
using Rift.Daemon.Core.Data;
using Rift.Daemon.Core.Interfaces;

namespace Rift.Daemon.Tests.Core;

public sealed class DiscoveryCoordinatorTests : IDisposable
{
    private readonly string _databasePath;
    private readonly DatabaseContext _databaseContext;
    private readonly SqliteTrustStore _trustStore;
    private readonly FakeDiscoveryService _discoveryService;
    private readonly FakeTimeProvider _timeProvider;

    public DiscoveryCoordinatorTests()
    {
        _databasePath = Path.Combine(Path.GetTempPath(), $"rift-discovery-{Guid.NewGuid():N}.db");
        _databaseContext = new DatabaseContext(_databasePath);
        _databaseContext.Initialize();
        _trustStore = new SqliteTrustStore(_databaseContext);
        _discoveryService = new FakeDiscoveryService();
        _timeProvider = new FakeTimeProvider(DateTimeOffset.Parse("2026-06-28T10:00:00Z"));
    }

    [Fact]
    public void ListDiscoveredPeers_PrunesPeersThatHaveGoneStale()
    {
        var coordinator = new DiscoveryCoordinator(
            _discoveryService,
            _trustStore,
            new FakeIdentityManager(),
            timeProvider: _timeProvider,
            peerTtl: TimeSpan.FromSeconds(30));

        coordinator.StartDiscovery();
        _discoveryService.EmitPeerDiscovered(new PeerDiscoveredEventArgs(
            deviceIdHint: "rift-stale-peer",
            instanceName: "inst-stale",
            host: "192.168.1.44",
            port: 9140,
            minVersion: "0.1-draft",
            maxVersion: "0.1-draft",
            txtRecord: new Dictionary<string, string> { ["did"] = "rift-stale-peer" },
            remoteEndPoint: new IPEndPoint(IPAddress.Parse("192.168.1.44"), 5353)));

        Assert.Contains(
            coordinator.ListDiscoveredPeers().Peers,
            peer => peer.DeviceId == "rift-stale-peer");

        _timeProvider.Advance(TimeSpan.FromSeconds(31));

        var result = coordinator.ListDiscoveredPeers();

        Assert.DoesNotContain(result.Peers, peer => peer.DeviceId == "rift-stale-peer");
    }

    [Fact]
    public void TryGetDiscoveredPeer_ReturnsFalseAfterPeerExpires()
    {
        var coordinator = new DiscoveryCoordinator(
            _discoveryService,
            _trustStore,
            new FakeIdentityManager(),
            timeProvider: _timeProvider,
            peerTtl: TimeSpan.FromSeconds(10));

        coordinator.StartDiscovery();
        _discoveryService.EmitPeerDiscovered(new PeerDiscoveredEventArgs(
            deviceIdHint: "rift-expiring-peer",
            instanceName: "inst-expiring",
            host: "192.168.1.55",
            port: 11112,
            minVersion: "0.1-draft",
            maxVersion: "0.1-draft",
            txtRecord: new Dictionary<string, string> { ["did"] = "rift-expiring-peer" },
            remoteEndPoint: new IPEndPoint(IPAddress.Parse("192.168.1.55"), 5353)));

        Assert.True(coordinator.TryGetDiscoveredPeer("rift-expiring-peer", out _));

        _timeProvider.Advance(TimeSpan.FromSeconds(11));

        Assert.False(coordinator.TryGetDiscoveredPeer("rift-expiring-peer", out _));
    }

    [Fact]
    public void StopDiscovery_ClearsDiscoveredCache()
    {
        var coordinator = new DiscoveryCoordinator(_discoveryService, _trustStore, new FakeIdentityManager(), timeProvider: _timeProvider);

        coordinator.StartDiscovery();
        _discoveryService.EmitPeerDiscovered(new PeerDiscoveredEventArgs(
            deviceIdHint: "rift-clear-peer",
            instanceName: "inst-clear",
            host: "192.168.1.66",
            port: 11112,
            minVersion: "0.1-draft",
            maxVersion: "0.1-draft",
            txtRecord: new Dictionary<string, string> { ["did"] = "rift-clear-peer" },
            remoteEndPoint: new IPEndPoint(IPAddress.Parse("192.168.1.66"), 5353)));

        coordinator.StopDiscovery();

        Assert.Empty(coordinator.ListDiscoveredPeers().Peers);
    }

    [Fact]
    public void ListDiscoveredPeers_PreservesMultipleObservedEndpointsForOnePeer()
    {
        var coordinator = new DiscoveryCoordinator(_discoveryService, _trustStore, new FakeIdentityManager(), timeProvider: _timeProvider);

        coordinator.StartDiscovery();
        _discoveryService.EmitPeerDiscovered(new PeerDiscoveredEventArgs(
            deviceIdHint: "rift-multi-endpoint",
            instanceName: "inst-v6",
            host: "2405:4802:6a20:e490:f093:96ff:fe22:d512",
            port: 11112,
            minVersion: "0.1-draft",
            maxVersion: "0.1-draft",
            txtRecord: new Dictionary<string, string> { ["did"] = "rift-multi-endpoint" },
            remoteEndPoint: new IPEndPoint(IPAddress.Parse("2405:4802:6a20:e490:f093:96ff:fe22:d512"), 5353)));

        _timeProvider.Advance(TimeSpan.FromSeconds(1));
        _discoveryService.EmitPeerDiscovered(new PeerDiscoveredEventArgs(
            deviceIdHint: "rift-multi-endpoint",
            instanceName: "inst-v4",
            host: "192.168.1.77",
            port: 11112,
            minVersion: "0.1-draft",
            maxVersion: "0.1-draft",
            txtRecord: new Dictionary<string, string> { ["did"] = "rift-multi-endpoint" },
            remoteEndPoint: new IPEndPoint(IPAddress.Parse("192.168.1.77"), 5353)));

        var peer = Assert.Single(coordinator.ListDiscoveredPeers().Peers);

        Assert.Equal("192.168.1.77", peer.Address);
        Assert.Equal(2, peer.ObservedEndpoints.Count);
        Assert.Equal("192.168.1.77", peer.ObservedEndpoints[0].Address);
    }

    [Fact]
    public void ListDiscoveredPeers_PreservesMultipleObservedAddressesFromSingleDiscoveryEvent()
    {
        var coordinator = new DiscoveryCoordinator(
            _discoveryService,
            _trustStore,
            new FakeIdentityManager(),
            timeProvider: _timeProvider);

        coordinator.StartDiscovery();
        _discoveryService.EmitPeerDiscovered(new PeerDiscoveredEventArgs(
            deviceIdHint: "rift-single-event-multi-address",
            instanceName: "inst-multi-address",
            host: "10.252.166.1",
            port: 9140,
            minVersion: "0.1-draft",
            maxVersion: "0.1-draft",
            txtRecord: new Dictionary<string, string> { ["did"] = "rift-single-event-multi-address" },
            remoteEndPoint: new IPEndPoint(IPAddress.Parse("10.252.166.1"), 5353),
            observedAddresses: ["10.252.166.1", "192.168.1.77"]));

        var peer = Assert.Single(coordinator.ListDiscoveredPeers().Peers);

        Assert.Equal(2, peer.ObservedEndpoints.Count);
        Assert.Contains(peer.ObservedEndpoints, endpoint => endpoint.Address == "10.252.166.1");
        Assert.Contains(peer.ObservedEndpoints, endpoint => endpoint.Address == "192.168.1.77");
    }

    [Fact]
    public void ListDiscoveredPeers_UsesScopedRemoteAddressForLinkLocalIpv6()
    {
        var coordinator = new DiscoveryCoordinator(
            _discoveryService,
            _trustStore,
            new FakeIdentityManager(),
            timeProvider: _timeProvider);

        coordinator.StartDiscovery();
        _discoveryService.EmitPeerDiscovered(new PeerDiscoveredEventArgs(
            deviceIdHint: "rift-link-local",
            instanceName: "inst-link-local",
            host: "fe80::18f1:f727:12a8:1b08",
            port: 11112,
            minVersion: "0.1-draft",
            maxVersion: "0.1-draft",
            txtRecord: new Dictionary<string, string> { ["did"] = "rift-link-local" },
            remoteEndPoint: new IPEndPoint(IPAddress.Parse("fe80::18f1:f727:12a8:1b08%7"), 5353),
            observedAddresses: ["fe80::18f1:f727:12a8:1b08"]));

        var peer = Assert.Single(coordinator.ListDiscoveredPeers().Peers);

        Assert.Equal("fe80::18f1:f727:12a8:1b08%7", peer.Address);
    }

    [Fact]
    public void ListDiscoveredPeers_KeepsExistingPrimaryForEqualScoreEndpoints()
    {
        var coordinator = new DiscoveryCoordinator(
            _discoveryService,
            _trustStore,
            new FakeIdentityManager(),
            timeProvider: _timeProvider);

        coordinator.StartDiscovery();
        _discoveryService.EmitPeerDiscovered(new PeerDiscoveredEventArgs(
            deviceIdHint: "rift-stable-primary",
            instanceName: "inst-stable-primary-1",
            host: "192.168.1.77",
            port: 9140,
            minVersion: "0.1-draft",
            maxVersion: "0.1-draft",
            txtRecord: new Dictionary<string, string> { ["did"] = "rift-stable-primary" },
            remoteEndPoint: new IPEndPoint(IPAddress.Parse("192.168.1.77"), 5353)));

        _timeProvider.Advance(TimeSpan.FromSeconds(1));
        _discoveryService.EmitPeerDiscovered(new PeerDiscoveredEventArgs(
            deviceIdHint: "rift-stable-primary",
            instanceName: "inst-stable-primary-2",
            host: "10.11.1.67",
            port: 9140,
            minVersion: "0.1-draft",
            maxVersion: "0.1-draft",
            txtRecord: new Dictionary<string, string> { ["did"] = "rift-stable-primary" },
            remoteEndPoint: new IPEndPoint(IPAddress.Parse("10.11.1.67"), 5353)));

        var peer = Assert.Single(coordinator.ListDiscoveredPeers().Peers);

        Assert.Equal("192.168.1.77", peer.Address);
        Assert.Equal("192.168.1.77", peer.ObservedEndpoints[0].Address);
        Assert.Equal("10.11.1.67", peer.ObservedEndpoints[1].Address);
    }

    public void Dispose()
    {
        SqliteConnection.ClearAllPools();
        if (File.Exists(_databasePath))
        {
            File.Delete(_databasePath);
        }
    }

    private sealed class FakeDiscoveryService : IDiscoveryService
    {
        public event EventHandler<PeerDiscoveredEventArgs>? PeerDiscovered;

        public void StartAdvertising(string deviceId, string minVersion, string maxVersion) { }

        public void StopAdvertising() { }

        public void StartDiscovery() { }

        public void StopDiscovery() { }

        public void EmitPeerDiscovered(PeerDiscoveredEventArgs args) => PeerDiscovered?.Invoke(this, args);
    }

    private sealed class FakeTimeProvider(DateTimeOffset utcNow) : TimeProvider
    {
        private DateTimeOffset _utcNow = utcNow;

        public override DateTimeOffset GetUtcNow() => _utcNow;

        public void Advance(TimeSpan delta) => _utcNow = _utcNow.Add(delta);
    }

    private sealed class FakeIdentityManager : IIdentityManager
    {
        public void EnsureIdentityInitialized() { }
        public string GetDeviceId() => "rift-local-device";
        public byte[] GetEd25519PublicKey() => throw new NotImplementedException();
        public System.Security.Cryptography.X509Certificates.X509Certificate2 GetTlsCertificate() => throw new NotImplementedException();
        public byte[] SignEd25519(byte[] data) => throw new NotImplementedException();
        public string GetFingerprint() => "local-fingerprint";
        public string GetDisplayName() => "Windows Desktop 01";
        public bool VerifyEd25519(byte[] publicKey, byte[] data, byte[] signature) => throw new NotImplementedException();
    }
}
