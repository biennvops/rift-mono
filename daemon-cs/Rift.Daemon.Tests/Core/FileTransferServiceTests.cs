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
    public async Task OfferFileAsync_ReconnectsWhenOnlyUnprotectedSessionExists()
    {
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer",
            State = TrustState.Trusted,
            Ed25519PublicKey = new byte[32],
            LastStateTransitionAt = DateTimeOffset.UtcNow,
            TrustedEndpoints =
            [
                new TrustedPeerEndpoint
                {
                    Address = "127.0.0.1",
                    Port = 7777,
                    LastSuccessAt = DateTimeOffset.UtcNow,
                    Source = "test"
                }
            ]
        });
        _presenceService.UpdatePeerPresence("rift-peer", "online", null, ["file.transfer"]);
        _transport.HasActiveSessionValue = true;
        _transport.HasProtectedSessionValue = false;

        var path = CreateTempFile("hello");
        try
        {
            await _service.OfferFileAsync("rift-peer", path, "demo.txt", "text/plain", CancellationToken.None);

            Assert.Equal(["rift-peer"], _transport.DisconnectedPeers);
            Assert.Equal([("127.0.0.1", 7777)], _transport.ConnectAttempts);
            Assert.Contains(_transport.SentMessages, sent => sent.PeerDeviceId == "rift-peer" && sent.Type == "file.offer");
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public async Task OfferFileAsync_ConcurrentReconnectOnlyDisconnectsOnce()
    {
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer",
            State = TrustState.Trusted,
            Ed25519PublicKey = new byte[32],
            LastStateTransitionAt = DateTimeOffset.UtcNow,
            TrustedEndpoints =
            [
                new TrustedPeerEndpoint
                {
                    Address = "127.0.0.1",
                    Port = 7777,
                    LastSuccessAt = DateTimeOffset.UtcNow,
                    Source = "test"
                }
            ]
        });
        _presenceService.UpdatePeerPresence("rift-peer", "online", null, ["file.transfer"]);
        _transport.HasActiveSessionValue = true;
        _transport.HasProtectedSessionValue = false;
        _transport.ConnectDelay = TimeSpan.FromMilliseconds(50);

        var pathOne = CreateTempFile("hello-one");
        var pathTwo = CreateTempFile("hello-two");
        try
        {
            await Task.WhenAll(
                _service.OfferFileAsync("rift-peer", pathOne, "demo-one.txt", "text/plain", CancellationToken.None),
                _service.OfferFileAsync("rift-peer", pathTwo, "demo-two.txt", "text/plain", CancellationToken.None));

            Assert.Equal(["rift-peer"], _transport.DisconnectedPeers);
            Assert.Equal([("127.0.0.1", 7777)], _transport.ConnectAttempts);
        }
        finally
        {
            File.Delete(pathOne);
            File.Delete(pathTwo);
        }
    }

    [Fact]
    public async Task OfferFileAsync_ReconnectsViaDiscoveryAfterDuplicateBootstrapRace()
    {
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer",
            State = TrustState.Trusted,
            Ed25519PublicKey = new byte[32],
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });
        _presenceService.UpdatePeerPresence("rift-peer", "online", null, ["file.transfer"]);
        _transport.HasActiveSessionValue = false;
        _transport.HasProtectedSessionValue = false;
        _transport.ConnectExceptions.Enqueue(new IOException("Received an unexpected EOF or 0 bytes from the transport stream."));
        _transport.ConnectExceptions.Enqueue(new IOException("Received an unexpected EOF or 0 bytes from the transport stream."));
        _discoveryCoordinator.DiscoveredPeer = new DiscoveredPeerInfo
        {
            DeviceId = "rift-peer",
            Address = "127.0.0.1",
            Port = 11112,
            ObservedEndpoints =
            [
                new DiscoveredPeerEndpoint
                {
                    Address = "127.0.0.1",
                    Port = 11112
                }
            ]
        };

        var path = CreateTempFile("hello");
        try
        {
            var result = await _service.OfferFileAsync("rift-peer", path, "demo.txt", "text/plain", CancellationToken.None);

            Assert.Equal("rift-peer", result.TargetDeviceId);
            Assert.Equal([("127.0.0.1", 11112), ("127.0.0.1", 11112), ("127.0.0.1", 11112)], _transport.ConnectAttempts);
            Assert.Contains(_transport.SentMessages, sent => sent.PeerDeviceId == "rift-peer" && sent.Type == "file.offer");
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
    public async Task HandleOfferReceivedAsync_RejectsOversizedIncomingOffer()
    {
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer",
            State = TrustState.Trusted,
            Ed25519PublicKey = new byte[32],
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });
        _presenceService.UpdatePeerPresence("rift-peer", "online", null, ["file.transfer"]);

        var ex = await Assert.ThrowsAsync<FileTransferFailureException>(() =>
            _service.HandleOfferReceivedAsync(new ReceivedFileOffer
            {
                DeviceId = "rift-peer",
                PayloadSourceDeviceId = "rift-peer",
                TransferId = "transfer-oversized",
                FileName = "huge.bin",
                MediaType = "application/octet-stream",
                ByteSize = (32L * 1024 * 1024) + 1,
                Sha256 = Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(Encoding.UTF8.GetBytes("hello"))),
                ChunkSize = 262144,
                ChunkCount = 1,
                ExpiresInMs = 120000,
                RequiredCapability = "file.transfer"
            }, CancellationToken.None));

        Assert.Equal("PayloadTooLarge", ex.FailureReason);
        var offers = await _service.ListIncomingFileOffersAsync();
        Assert.DoesNotContain(offers.Offers, offer => offer.TransferId == "transfer-oversized");
    }

    [Theory]
    [InlineData(-1, 120000)]
    [InlineData(5, 0)]
    [InlineData(5, -1)]
    public async Task HandleOfferReceivedAsync_RejectsMalformedByteSizeOrExpiry(long byteSize, long expiresInMs)
    {
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer",
            State = TrustState.Trusted,
            Ed25519PublicKey = new byte[32],
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });
        _presenceService.UpdatePeerPresence("rift-peer", "online", null, ["file.transfer"]);

        var ex = await Assert.ThrowsAsync<FileTransferFailureException>(() =>
            _service.HandleOfferReceivedAsync(new ReceivedFileOffer
            {
                DeviceId = "rift-peer",
                PayloadSourceDeviceId = "rift-peer",
                TransferId = "transfer-malformed",
                FileName = "bad.bin",
                MediaType = "application/octet-stream",
                ByteSize = byteSize,
                Sha256 = Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(Encoding.UTF8.GetBytes("hello"))),
                ChunkSize = 262144,
                ChunkCount = 1,
                ExpiresInMs = expiresInMs,
                RequiredCapability = "file.transfer"
            }, CancellationToken.None));

        Assert.Equal("ProtocolError", ex.FailureReason);
        var offers = await _service.ListIncomingFileOffersAsync();
        Assert.DoesNotContain(offers.Offers, offer => offer.TransferId == "transfer-malformed");
    }

    [Fact]
    public async Task AcceptFileOfferAsync_RejectsDotOnlyIncomingFileName()
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
            TransferId = "transfer-dot-only",
            FileName = ".",
            MediaType = "text/plain",
            ByteSize = 5,
            Sha256 = Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(Encoding.UTF8.GetBytes("hello"))),
            ChunkSize = 262144,
            ChunkCount = 1,
            ExpiresInMs = 120000,
            RequiredCapability = "file.transfer"
        }, CancellationToken.None);

        var destination = Path.Combine(Path.GetTempPath(), $"rift-dest-{Guid.NewGuid():N}.txt");
        var ex = await Assert.ThrowsAsync<FileTransferFailureException>(() =>
            _service.AcceptFileOfferAsync("transfer-dot-only", destination, overwrite: false, CancellationToken.None));

        Assert.Equal("ProtocolError", ex.FailureReason);
        Assert.Contains("invalid file name", ex.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task HandleChunkReceivedAsync_DoesNotEscapeStagingDirectoryForIncomingFileName()
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
        const string transferId = "transfer-traversal";
        await _service.HandleOfferReceivedAsync(new ReceivedFileOffer
        {
            DeviceId = "rift-peer",
            PayloadSourceDeviceId = "rift-peer",
            TransferId = transferId,
            FileName = "..\\..\\escaped",
            MediaType = "text/plain",
            ByteSize = bytes.Length,
            Sha256 = sha,
            ChunkSize = 262144,
            ChunkCount = 1,
            ExpiresInMs = 120000,
            RequiredCapability = "file.transfer"
        }, CancellationToken.None);

        var destination = Path.Combine(Path.GetTempPath(), $"rift-saved-{Guid.NewGuid():N}.txt");
        var escapedPath = Path.Combine(Path.GetTempPath(), "escaped.part");
        try
        {
            if (File.Exists(escapedPath))
            {
                File.Delete(escapedPath);
            }

            await _service.AcceptFileOfferAsync(transferId, destination, overwrite: false, CancellationToken.None);
            await _service.HandleChunkReceivedAsync(
                "rift-peer",
                transferId,
                0,
                0,
                bytes.Length,
                sha,
                Convert.ToBase64String(bytes),
                true,
                CancellationToken.None);

            Assert.False(File.Exists(escapedPath));
        }
        finally
        {
            if (File.Exists(escapedPath))
            {
                File.Delete(escapedPath);
            }

            if (File.Exists(destination))
            {
                File.Delete(destination);
            }
        }
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
    public async Task HandleAcceptReceivedAsync_RejectsAuthenticatedPeerThatDoesNotOwnTransfer()
    {
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer",
            State = TrustState.Trusted,
            Ed25519PublicKey = new byte[32],
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer-other",
            State = TrustState.Trusted,
            Ed25519PublicKey = new byte[32],
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });
        _presenceService.UpdatePeerPresence("rift-peer", "online", null, ["file.transfer"]);
        _presenceService.UpdatePeerPresence("rift-peer-other", "online", null, ["file.transfer"]);

        var path = CreateTempFile("hello");
        try
        {
            var offer = await _service.OfferFileAsync("rift-peer", path, "demo.txt", "text/plain", CancellationToken.None);

            var ex = await Assert.ThrowsAsync<FileTransferFailureException>(() =>
                _service.HandleAcceptReceivedAsync("rift-peer-other", offer.TransferId, "rift-peer-other", 262144, CancellationToken.None));

            Assert.Equal("Unauthorized", ex.FailureReason);
            Assert.DoesNotContain(_transport.SentMessages, sent => sent.Type == "file.chunk");
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public async Task HandleRejectReceivedAsync_RejectsAuthenticatedPeerThatDoesNotOwnTransfer()
    {
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer",
            State = TrustState.Trusted,
            Ed25519PublicKey = new byte[32],
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer-other",
            State = TrustState.Trusted,
            Ed25519PublicKey = new byte[32],
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });
        _presenceService.UpdatePeerPresence("rift-peer", "online", null, ["file.transfer"]);
        _presenceService.UpdatePeerPresence("rift-peer-other", "online", null, ["file.transfer"]);

        var path = CreateTempFile("hello");
        try
        {
            var offer = await _service.OfferFileAsync("rift-peer", path, "demo.txt", "text/plain", CancellationToken.None);

            var ex = await Assert.ThrowsAsync<FileTransferFailureException>(() =>
                _service.HandleRejectReceivedAsync("rift-peer-other", offer.TransferId, "PolicyDenied", "spoofed reject", CancellationToken.None));

            Assert.Equal("Unauthorized", ex.FailureReason);
            Assert.DoesNotContain(_notifications.Notifications, note => note.Method == "rift.onFileTransferFailed");
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public async Task HandleRejectReceivedAsync_RemovesRejectedOutgoingTransferFromListings()
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

            Assert.Contains((await _service.ListFileTransfersAsync()).Transfers, transfer => transfer.TransferId == offer.TransferId);

            await _service.HandleRejectReceivedAsync("rift-peer", offer.TransferId, "PolicyDenied", "peer rejected", CancellationToken.None);

            Assert.DoesNotContain((await _service.ListFileTransfersAsync()).Transfers, transfer => transfer.TransferId == offer.TransferId);
            Assert.Contains(_notifications.Notifications, note => note.Method == "rift.onFileTransferFailed");
            Assert.Equal("Failed", _operationService.GetOperation(offer.OperationId).State);
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public async Task HandleRejectReceivedAsync_UsesClosedProtocolEventVocabulary()
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

            await _service.HandleRejectReceivedAsync("rift-peer", offer.TransferId, "PolicyDenied", "peer rejected", CancellationToken.None);

            Assert.DoesNotContain(_securityEventLog.Records, record => record.EventType.StartsWith("file.", StringComparison.Ordinal));
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public async Task HandleCancelReceivedAsync_StopsOutgoingTransferAfterPeerCancel()
    {
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer",
            State = TrustState.Trusted,
            Ed25519PublicKey = new byte[32],
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });
        _presenceService.UpdatePeerPresence("rift-peer", "online", null, ["file.transfer"]);

        _transport.BlockChunkSends = true;
        var path = CreateTempFile(new string('a', 600000));
        try
        {
            var offer = await _service.OfferFileAsync("rift-peer", path, "demo.txt", "text/plain", CancellationToken.None);

            await _service.HandleAcceptReceivedAsync("rift-peer", offer.TransferId, "rift-peer", 262144, CancellationToken.None);
            await WaitForConditionAsync(() => _transport.BlockedChunkSendCount > 0, TimeSpan.FromSeconds(1));

            await _service.HandleCancelReceivedAsync("rift-peer", offer.TransferId, "PolicyDenied", "peer cancelled", CancellationToken.None);
            _transport.ReleaseBlockedChunkSends();
            await WaitForConditionAsync(
                () => _notifications.Notifications.Any(note => note.Method == "rift.onFileTransferFailed"),
                TimeSpan.FromSeconds(1));

            Assert.Equal(1, _transport.SentMessages.Count(sent => sent.Type == "file.chunk"));
            Assert.DoesNotContain(_transport.SentMessages, sent => sent.Type == "file.complete");
        }
        finally
        {
            _transport.BlockChunkSends = false;
            _transport.ReleaseBlockedChunkSends();
            File.Delete(path);
        }
    }

    [Fact]
    public async Task HandleCancelReceivedAsync_RejectsAuthenticatedPeerThatDoesNotOwnOutgoingTransfer()
    {
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer",
            State = TrustState.Trusted,
            Ed25519PublicKey = new byte[32],
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer-other",
            State = TrustState.Trusted,
            Ed25519PublicKey = new byte[32],
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });
        _presenceService.UpdatePeerPresence("rift-peer", "online", null, ["file.transfer"]);
        _presenceService.UpdatePeerPresence("rift-peer-other", "online", null, ["file.transfer"]);

        _transport.BlockChunkSends = true;
        var path = CreateTempFile(new string('a', 600000));
        try
        {
            var offer = await _service.OfferFileAsync("rift-peer", path, "demo.txt", "text/plain", CancellationToken.None);
            await _service.HandleAcceptReceivedAsync("rift-peer", offer.TransferId, "rift-peer", 262144, CancellationToken.None);
            await WaitForConditionAsync(() => _transport.BlockedChunkSendCount > 0, TimeSpan.FromSeconds(1));

            var ex = await Assert.ThrowsAsync<FileTransferFailureException>(() =>
                _service.HandleCancelReceivedAsync("rift-peer-other", offer.TransferId, "PolicyDenied", "spoofed cancel", CancellationToken.None));

            Assert.Equal("Unauthorized", ex.FailureReason);

            _transport.ReleaseBlockedChunkSends();
            await WaitForConditionAsync(() => _transport.SentMessages.Any(sent => sent.Type == "file.complete"), TimeSpan.FromSeconds(1));
        }
        finally
        {
            _transport.BlockChunkSends = false;
            _transport.ReleaseBlockedChunkSends();
            File.Delete(path);
        }
    }

    [Fact]
    public async Task HandleCancelReceivedAsync_RejectsAuthenticatedPeerThatDoesNotOwnIncomingTransfer()
    {
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer",
            State = TrustState.Trusted,
            Ed25519PublicKey = new byte[32],
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer-other",
            State = TrustState.Trusted,
            Ed25519PublicKey = new byte[32],
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });
        _presenceService.UpdatePeerPresence("rift-peer", "online", null, ["file.transfer"]);
        _presenceService.UpdatePeerPresence("rift-peer-other", "online", null, ["file.transfer"]);

        var bytes = Encoding.UTF8.GetBytes("hello");
        var sha = Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(bytes));
        const string transferId = "transfer-cancel-incoming";
        await _service.HandleOfferReceivedAsync(new ReceivedFileOffer
        {
            DeviceId = "rift-peer",
            PayloadSourceDeviceId = "rift-peer",
            TransferId = transferId,
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
            await _service.AcceptFileOfferAsync(transferId, destination, overwrite: false, CancellationToken.None);

            var ex = await Assert.ThrowsAsync<FileTransferFailureException>(() =>
                _service.HandleCancelReceivedAsync("rift-peer-other", transferId, "PolicyDenied", "spoofed cancel", CancellationToken.None));

            Assert.Equal("Unauthorized", ex.FailureReason);

            await _service.HandleChunkReceivedAsync(
                "rift-peer",
                transferId,
                0,
                0,
                bytes.Length,
                sha,
                Convert.ToBase64String(bytes),
                true,
                CancellationToken.None);
        }
        finally
        {
            if (File.Exists(destination))
            {
                File.Delete(destination);
            }
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

        public string GetDisplayName() => "Windows Desktop 01";

        public bool VerifyEd25519(byte[] publicKey, byte[] data, byte[] signature) => true;
    }

    private sealed class InMemoryTrustStore : ITrustStore
    {
        private readonly Dictionary<string, PeerIdentity> _peers = new(StringComparer.Ordinal);

        public void SavePeer(PeerIdentity peer) => _peers[peer.DeviceId] = peer;

        public PeerIdentity? GetPeer(string deviceId) => _peers.TryGetValue(deviceId, out var peer) ? peer : null;
        
        public void DeletePeer(string deviceId) => _peers.Remove(deviceId);

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
        public DiscoveredPeerInfo? DiscoveredPeer { get; set; }

        public DiscoveryToggleResult StartDiscovery() => new() { Started = true };

        public DiscoveryToggleResult StopDiscovery() => new() { Stopped = true };

        public ListDiscoveredPeersResult ListDiscoveredPeers() => new();

        public bool TryGetDiscoveredPeer(string deviceId, out DiscoveredPeerInfo? peer)
        {
            if (DiscoveredPeer is not null && string.Equals(DiscoveredPeer.DeviceId, deviceId, StringComparison.Ordinal))
            {
                peer = DiscoveredPeer;
                return true;
            }

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
        private readonly TaskCompletionSource _releaseBlockedChunkSends =
            new(TaskCreationOptions.RunContinuationsAsynchronously);

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
        public List<(string Host, int Port)> ConnectAttempts { get; } = [];
        public List<string> DisconnectedPeers { get; } = [];
        public Queue<Exception> ConnectExceptions { get; } = new();
        public bool BlockChunkSends { get; set; }
        public int BlockedChunkSendCount { get; private set; }
        public bool HasActiveSessionValue { get; set; } = true;
        public bool HasProtectedSessionValue { get; set; } = true;
        public TimeSpan ConnectDelay { get; set; } = TimeSpan.Zero;

        public Task StartListeningAsync(CancellationToken cancellationToken) => Task.CompletedTask;

        public async Task ConnectToPeerAsync(string host, int port, CancellationToken cancellationToken)
        {
            ConnectAttempts.Add((host, port));
            if (ConnectDelay > TimeSpan.Zero)
            {
                await Task.Delay(ConnectDelay, cancellationToken);
            }
            if (ConnectExceptions.Count > 0)
            {
                throw ConnectExceptions.Dequeue();
            }
            HasActiveSessionValue = true;
            HasProtectedSessionValue = true;
        }

        public Task<string> ConnectToPeerWithIdentityAsync(string host, int port, CancellationToken cancellationToken) =>
            Task.FromResult("rift-peer");

        public Task SendAsync(string peerDeviceId, ReadOnlyMemory<byte> frameBody, CancellationToken cancellationToken)
        {
            using var document = JsonDocument.Parse(frameBody);
            var type = document.RootElement.GetProperty("type").GetString() ?? string.Empty;
            var payload = document.RootElement.GetProperty("payload").Clone();
            SentMessages.Add((peerDeviceId, type, payload));
            if (BlockChunkSends && string.Equals(type, "file.chunk", StringComparison.Ordinal))
            {
                BlockedChunkSendCount++;
                return _releaseBlockedChunkSends.Task.WaitAsync(cancellationToken);
            }

            return Task.CompletedTask;
        }

        public bool HasActiveSession(string peerDeviceId) => HasActiveSessionValue;

        public bool HasProtectedSession(string peerDeviceId) => HasProtectedSessionValue;

        public void RefreshSessionAuthorization(string peerDeviceId) { }

        public PeerSessionEndpoint? GetPeerSessionEndpoint(string peerDeviceId) => null;

        public Task DisconnectPeerAsync(string peerDeviceId, CancellationToken cancellationToken)
        {
            DisconnectedPeers.Add(peerDeviceId);
            HasActiveSessionValue = false;
            HasProtectedSessionValue = false;
            return Task.CompletedTask;
        }

        public void ReleaseBlockedChunkSends()
        {
            _releaseBlockedChunkSends.TrySetResult();
        }
    }
}
