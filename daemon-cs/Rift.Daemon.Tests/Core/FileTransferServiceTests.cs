using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Text.Json;
using Microsoft.Extensions.Logging.Abstractions;
using Rift.Daemon.Core;
using Rift.Daemon.Core.Interfaces;

namespace Rift.Daemon.Tests.Core;

public sealed class FileTransferServiceTests : IDisposable
{
    private readonly InMemoryTrustStore _trustStore = new();
    private readonly InMemorySecurityEventLog _securityEventLog = new();
    private readonly PresenceService _presenceService = new();
    private readonly FakeDiscoveryCoordinator _discoveryCoordinator = new();
    private readonly FakeTransport _transport = new();
    private readonly FakeIdentityManager _identityManager = new("rift-local-device");
    private readonly OperationService _operationService;
    private readonly RecordingNotificationService _notifications = new();
    private readonly FileTransferService _service;

    public FileTransferServiceTests()
    {
        _operationService = new OperationService(null, _securityEventLog, _identityManager, NullLogger<OperationService>.Instance);
        _service = new FileTransferService(
            _transport,
            _trustStore,
            _discoveryCoordinator,
            _presenceService,
            _identityManager,
            _securityEventLog,
            _operationService,
            _notifications,
            NullLogger<FileTransferService>.Instance);
    }

    [Fact]
    public async Task OfferFileAsync_SendsMetadataOnlyOffer()
    {
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer",
            State = TrustState.Trusted,
            Ed25519PublicKey = new byte[32],
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });
        _presenceService.UpdatePeerPresence("rift-peer", "online", null, ["file.transfer"]);

        var path = CreateTempFile("hello");
        try
        {
            var result = await _service.OfferFileAsync("rift-peer", path, "demo.txt", "text/plain", CancellationToken.None);

            Assert.Equal("rift-peer", result.TargetDeviceId);
            Assert.Contains(_transport.SentMessages, sent => sent.PeerDeviceId == "rift-peer" && sent.Type == "file.offer");
            Assert.DoesNotContain(_transport.SentMessages, sent => sent.Type == "file.chunk");
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public async Task AcceptFileOfferAsync_SendsAcceptMessage()
    {
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer",
            State = TrustState.Trusted,
            Ed25519PublicKey = new byte[32],
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });
        _presenceService.UpdatePeerPresence("rift-peer", "online", null, ["file.transfer"]);

        await _service.HandleOfferReceivedAsync(new ReceivedFileOffer
        {
            DeviceId = "rift-peer",
            PayloadSourceDeviceId = "rift-peer",
            TransferId = "transfer-incoming",
            FileName = "photo.jpg",
            MediaType = "image/jpeg",
            ByteSize = 5,
            Sha256 = Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(Encoding.UTF8.GetBytes("hello"))),
            ChunkSize = 262144,
            ChunkCount = 1,
            ExpiresInMs = 120000,
            RequiredCapability = "file.transfer"
        }, CancellationToken.None);

        var destination = Path.Combine(Path.GetTempPath(), $"rift-dest-{Guid.NewGuid():N}.jpg");
        var result = await _service.AcceptFileOfferAsync("transfer-incoming", destination, overwrite: false, CancellationToken.None);

        Assert.Equal("transfer-incoming", result.TransferId);
        Assert.Contains(_transport.SentMessages, sent => sent.PeerDeviceId == "rift-peer" && sent.Type == "file.accept");
    }

    [Fact]
    public async Task HandleAcceptReceivedAsync_SendsChunksAndComplete()
    {
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer",
            State = TrustState.Trusted,
            Ed25519PublicKey = new byte[32],
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });
        _presenceService.UpdatePeerPresence("rift-peer", "online", null, ["file.transfer"]);

        var path = CreateTempFile("hello");
        try
        {
            var offer = await _service.OfferFileAsync("rift-peer", path, "demo.txt", "text/plain", CancellationToken.None);

            await _service.HandleAcceptReceivedAsync("rift-peer", offer.TransferId, "rift-peer", 262144, CancellationToken.None);

            await WaitForConditionAsync(() => _transport.SentMessages.Any(sent => sent.Type == "file.chunk"), TimeSpan.FromSeconds(1));
            await WaitForConditionAsync(
                () => _operationService.GetOperation(offer.OperationId).State == "Done",
                TimeSpan.FromSeconds(1));
            Assert.Contains(_transport.SentMessages, sent => sent.Type == "file.complete");
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public async Task HandleChunkAndCompleteReceived_WritesDestinationFile()
    {
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer",
            State = TrustState.Trusted,
            Ed25519PublicKey = new byte[32],
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });
        _presenceService.UpdatePeerPresence("rift-peer", "online", null, ["file.transfer"]);

        var bytes = Encoding.UTF8.GetBytes("hello");
        var sha = Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(bytes));
        await _service.HandleOfferReceivedAsync(new ReceivedFileOffer
        {
            DeviceId = "rift-peer",
            PayloadSourceDeviceId = "rift-peer",
            TransferId = "transfer-store",
            FileName = "saved.txt",
            MediaType = "text/plain",
            ByteSize = bytes.Length,
            Sha256 = sha,
            ChunkSize = 262144,
            ChunkCount = 1,
            ExpiresInMs = 120000,
            RequiredCapability = "file.transfer"
        }, CancellationToken.None);

        var destination = Path.Combine(Path.GetTempPath(), $"rift-saved-{Guid.NewGuid():N}.txt");
        try
        {
            await _service.AcceptFileOfferAsync("transfer-store", destination, overwrite: false, CancellationToken.None);
            await _service.HandleChunkReceivedAsync(
                "rift-peer",
                "transfer-store",
                0,
                0,
                bytes.Length,
                sha,
                Convert.ToBase64String(bytes),
                true,
                CancellationToken.None);
            await _service.HandleCompleteReceivedAsync(
                "rift-peer",
                "transfer-store",
                bytes.Length,
                sha,
                1,
                CancellationToken.None);

            Assert.True(File.Exists(destination));
            Assert.Equal("hello", await File.ReadAllTextAsync(destination));
            Assert.Contains(_notifications.Notifications, note => note.Method == "rift.onFileTransferCompleted");
        }
        finally
        {
            if (File.Exists(destination))
            {
                File.Delete(destination);
            }
        }
    }

    public void Dispose()
    {
    }

    private static string CreateTempFile(string content)
    {
        var path = Path.Combine(Path.GetTempPath(), $"rift-file-{Guid.NewGuid():N}.tmp");
        File.WriteAllText(path, content);
        return path;
    }

    private static async Task WaitForConditionAsync(Func<bool> condition, TimeSpan timeout)
    {
        var deadline = DateTime.UtcNow.Add(timeout);
        while (!condition())
        {
            if (DateTime.UtcNow >= deadline)
            {
                throw new TimeoutException("Condition was not met within the allotted time.");
            }

            await Task.Delay(10);
        }
    }

    private sealed class FakeIdentityManager(string deviceId) : IIdentityManager
    {
        public void EnsureIdentityInitialized()
        {
        }

        public string GetDeviceId() => deviceId;

        public byte[] GetEd25519PublicKey() => new byte[32];

        public X509Certificate2 GetTlsCertificate() => throw new NotSupportedException();

        public byte[] SignEd25519(byte[] data) => [];

        public string GetFingerprint() => "FAKE-FINGERPRINT";

        public bool VerifyEd25519(byte[] publicKey, byte[] data, byte[] signature) => true;
    }

    private sealed class InMemoryTrustStore : ITrustStore
    {
        private readonly Dictionary<string, PeerIdentity> _peers = new(StringComparer.Ordinal);

        public void SavePeer(PeerIdentity peer) => _peers[peer.DeviceId] = peer;

        public PeerIdentity? GetPeer(string deviceId) => _peers.TryGetValue(deviceId, out var peer) ? peer : null;

        public IEnumerable<PeerIdentity> GetAllPeers() => _peers.Values;

        public bool TryTransition(string deviceId, TrustState newState)
        {
            if (!_peers.TryGetValue(deviceId, out var peer))
            {
                return false;
            }

            peer.State = newState;
            return true;
        }

        public void RevokePeer(string deviceId, string revocationEvidence)
        {
            if (_peers.TryGetValue(deviceId, out var peer))
            {
                peer.State = TrustState.Revoked;
                peer.RevocationEvidence = revocationEvidence;
            }
        }
    }

    private sealed class InMemorySecurityEventLog : ISecurityEventLog
    {
        public readonly List<SecurityEventRecord> Records = [];

        public Task LogEventAsync(SecurityEventRecord securityEvent)
        {
            Records.Add(securityEvent);
            return Task.CompletedTask;
        }

        public Task<IReadOnlyList<SecurityEventRecord>> QueryEventsAsync(SecurityEventQuery query)
        {
            return Task.FromResult<IReadOnlyList<SecurityEventRecord>>(Records);
        }
    }

    private sealed class FakeDiscoveryCoordinator : IDiscoveryCoordinator
    {
        public DiscoveryToggleResult StartDiscovery() => new() { Started = true };

        public DiscoveryToggleResult StopDiscovery() => new() { Stopped = true };

        public ListDiscoveredPeersResult ListDiscoveredPeers() => new();

        public bool TryGetDiscoveredPeer(string deviceId, out DiscoveredPeerInfo? peer)
        {
            peer = null;
            return false;
        }
    }

    private sealed class RecordingNotificationService : IIpcNotificationService
    {
        public List<(string Method, object Parameters)> Notifications { get; } = [];

        public IDisposable RegisterClient(StreamJsonRpc.JsonRpc jsonRpc) => throw new NotSupportedException();

        public Task NotifyAsync(string method, object parameters, CancellationToken cancellationToken = default)
        {
            Notifications.Add((method, parameters));
            return Task.CompletedTask;
        }
    }

    private sealed class FakeTransport : ITransport
    {
        public event EventHandler<MessageReceivedEventArgs>? MessageReceived
        {
            add { }
            remove { }
        }

        public event EventHandler<SessionStateChangedEventArgs>? SessionStateChanged
        {
            add { }
            remove { }
        }

        public List<(string PeerDeviceId, string Type, JsonElement Payload)> SentMessages { get; } = [];

        public Task StartListeningAsync(CancellationToken cancellationToken) => Task.CompletedTask;

        public Task ConnectToPeerAsync(string host, int port, CancellationToken cancellationToken) => Task.CompletedTask;

        public Task<string> ConnectToPeerWithIdentityAsync(string host, int port, CancellationToken cancellationToken) =>
            Task.FromResult("rift-peer");

        public Task SendAsync(string peerDeviceId, ReadOnlyMemory<byte> frameBody, CancellationToken cancellationToken)
        {
            using var document = JsonDocument.Parse(frameBody);
            var type = document.RootElement.GetProperty("type").GetString() ?? string.Empty;
            var payload = document.RootElement.GetProperty("payload").Clone();
            SentMessages.Add((peerDeviceId, type, payload));
            return Task.CompletedTask;
        }

        public bool HasActiveSession(string peerDeviceId) => true;

        public PeerSessionEndpoint? GetPeerSessionEndpoint(string peerDeviceId) => null;

        public Task DisconnectPeerAsync(string peerDeviceId, CancellationToken cancellationToken) => Task.CompletedTask;
    }
}
