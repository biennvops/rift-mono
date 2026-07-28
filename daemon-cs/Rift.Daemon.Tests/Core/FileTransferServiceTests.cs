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
            await TestFiles.DeleteWithRetryAsync(path);
        }
    }

    [Fact]
    public async Task OfferFileAsync_UsesPositiveChunkCountForEmptyFile()
    {
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer",
            State = TrustState.Trusted,
            Ed25519PublicKey = new byte[32],
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });
        _presenceService.UpdatePeerPresence("rift-peer", "online", null, ["file.transfer"]);

        var path = CreateTempFile(string.Empty);
        try
        {
            var result = await _service.OfferFileAsync("rift-peer", path, "empty.txt", "text/plain", CancellationToken.None);
            var offer = _transport.SentMessages.Single(sent => sent.Type == "file.offer");

            Assert.Equal(1, result.ChunkCount);
            Assert.Equal(1, offer.Payload.GetProperty("chunkCount").GetInt32());

            await _service.HandleAcceptReceivedAsync("rift-peer", result.TransferId, "rift-peer", 262144, CancellationToken.None);
            await WaitForConditionAsync(
                () => _notifications.Notifications.Any(note => note.Method == "rift.onFileTransferCompleted"),
                TimeSpan.FromSeconds(1));

            var chunk = _transport.SentMessages.Single(sent => sent.Type == "file.chunk");
            Assert.Equal(0, chunk.Payload.GetProperty("chunkIndex").GetInt32());
            Assert.Equal(0, chunk.Payload.GetProperty("byteSize").GetInt32());
            Assert.Equal(string.Empty, chunk.Payload.GetProperty("contentBase64").GetString());
            Assert.True(chunk.Payload.GetProperty("isLastChunk").GetBoolean());
            Assert.Equal("Done", _operationService.GetOperation(result.OperationId).State);
        }
        finally
        {
            await TestFiles.DeleteWithRetryAsync(path);
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
            await TestFiles.DeleteWithRetryAsync(path);
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
            await TestFiles.DeleteWithRetryAsync(path);
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
    public async Task HandleOfferReceivedAsync_AcceptsFileLargerThanFrameLimit()
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
            TransferId = "transfer-large",
            FileName = "large.bin",
            MediaType = "application/octet-stream",
            ByteSize = (32L * 1024 * 1024) + 1,
            Sha256 = Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(Encoding.UTF8.GetBytes("hello"))),
            ChunkSize = 262144,
            ChunkCount = 129,
            ExpiresInMs = 120000,
            RequiredCapability = "file.transfer"
        }, CancellationToken.None);

        var offer = Assert.Single((await _service.ListIncomingFileOffersAsync()).Offers);
        Assert.Equal("transfer-large", offer.TransferId);
        Assert.Equal((32L * 1024 * 1024) + 1, offer.ByteSize);
    }

    [Theory]
    [InlineData(-1, 120000, 1)]
    [InlineData(5, 0, 1)]
    [InlineData(5, -1, 1)]
    [InlineData(0, 120000, 0)]
    public async Task HandleOfferReceivedAsync_RejectsMalformedMetadata(long byteSize, long expiresInMs, int chunkCount)
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
                ChunkCount = chunkCount,
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
            await TestFiles.DeleteWithRetryAsync(path);
        }
    }

    [Fact]
    public async Task HandleResumeReceivedAsync_RejectsOfferedAndActiveTransfers()
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

            var offeredError = await Assert.ThrowsAsync<FileTransferFailureException>(() =>
                _service.HandleResumeReceivedAsync("rift-peer", offer.TransferId, "rift-peer", 0, 0, CancellationToken.None));
            Assert.Equal("ProtocolError", offeredError.FailureReason);
            Assert.DoesNotContain(_transport.SentMessages, sent => sent.Type == "file.chunk");

            await _service.HandleAcceptReceivedAsync("rift-peer", offer.TransferId, "rift-peer", 262144, CancellationToken.None);
            await WaitForConditionAsync(() => _transport.BlockedChunkSendCount == 1, TimeSpan.FromSeconds(1));

            var activeError = await Assert.ThrowsAsync<FileTransferFailureException>(() =>
                _service.HandleResumeReceivedAsync("rift-peer", offer.TransferId, "rift-peer", 0, 0, CancellationToken.None));
            Assert.Equal("ProtocolError", activeError.FailureReason);
            Assert.Equal(1, _transport.SentMessages.Count(sent => sent.Type == "file.chunk"));
        }
        finally
        {
            _transport.BlockChunkSends = false;
            _transport.ReleaseBlockedChunkSends();
            await DeleteTempFileAsync(path);
        }
    }

    [Fact]
    public async Task HandleAcceptReceivedAsync_UsesNegotiatedChunkCount()
    {
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer",
            State = TrustState.Trusted,
            Ed25519PublicKey = new byte[32],
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });
        _presenceService.UpdatePeerPresence("rift-peer", "online", null, ["file.transfer"]);

        var path = CreateTempFile(new string('a', 600000));
        try
        {
            var offer = await _service.OfferFileAsync("rift-peer", path, "demo.txt", "text/plain", CancellationToken.None);
            Assert.Equal(3, offer.ChunkCount);

            await _service.HandleAcceptReceivedAsync("rift-peer", offer.TransferId, "rift-peer", 524288, CancellationToken.None);
            await WaitForConditionAsync(
                () => _operationService.GetOperation(offer.OperationId).State == "Done",
                TimeSpan.FromSeconds(1));

            Assert.Equal(2, _transport.SentMessages.Count(sent => sent.Type == "file.chunk"));
            var complete = _transport.SentMessages.Single(sent => sent.Type == "file.complete");
            Assert.Equal(2, complete.Payload.GetProperty("chunkCount").GetInt32());
        }
        finally
        {
            await TestFiles.DeleteWithRetryAsync(path);
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
            await TestFiles.DeleteWithRetryAsync(path);
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
            await TestFiles.DeleteWithRetryAsync(path);
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
            await TestFiles.DeleteWithRetryAsync(path);
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
            await TestFiles.DeleteWithRetryAsync(path);
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
            await TestFiles.DeleteWithRetryAsync(path);
        }
    }

    [Fact]
    public async Task OutgoingConnectionLost_PreservesTransferStateForResume()
    {
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer",
            State = TrustState.Trusted,
            Ed25519PublicKey = new byte[32],
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });
        _presenceService.UpdatePeerPresence("rift-peer", "online", null, ["file.transfer"]);
        _transport.FailChunkSendOnce = true;

        var path = CreateTempFile(new string('a', 600000));
        try
        {
            var offer = await _service.OfferFileAsync("rift-peer", path, "demo.txt", "text/plain", CancellationToken.None);

            await _service.HandleAcceptReceivedAsync("rift-peer", offer.TransferId, "rift-peer", 262144, CancellationToken.None);
            await WaitForConditionAsync(
                () => _notifications.Notifications.Any(note => note.Method == "rift.onFileTransferFailed"),
                TimeSpan.FromSeconds(1));

            var transfers = await _service.ListFileTransfersAsync();
            Assert.Contains(transfers.Transfers, transfer =>
                transfer.TransferId == offer.TransferId &&
                transfer.Direction == "outgoing" &&
                transfer.State == "Active" &&
                transfer.FailureReason is null);
            Assert.Equal("Active", _operationService.GetOperation(offer.OperationId).State);
        }
        finally
        {
            await TestFiles.DeleteWithRetryAsync(path);
        }
    }

    [Fact]
    public async Task ResumeDuringFailureNotification_UsesPublishedPausedState()
    {
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer",
            State = TrustState.Trusted,
            Ed25519PublicKey = new byte[32],
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });
        _presenceService.UpdatePeerPresence("rift-peer", "online", null, ["file.transfer"]);
        _transport.FailChunkSendOnce = true;
        _notifications.BlockTransferFailedNotification = true;

        var path = CreateTempFile(new string('a', 600000));
        try
        {
            var offer = await _service.OfferFileAsync("rift-peer", path, "demo.txt", "text/plain", CancellationToken.None);
            await _service.HandleAcceptReceivedAsync("rift-peer", offer.TransferId, "rift-peer", 262144, CancellationToken.None);
            await _notifications.TransferFailedNotificationEntered.WaitAsync(TimeSpan.FromSeconds(1));

            await _service.HandleResumeReceivedAsync("rift-peer", offer.TransferId, "rift-peer", 0, 0, CancellationToken.None);
            await WaitForConditionAsync(
                () => _notifications.Notifications.Any(note => note.Method == "rift.onFileTransferCompleted"),
                TimeSpan.FromSeconds(1));

            Assert.Equal("Done", _operationService.GetOperation(offer.OperationId).State);
            Assert.DoesNotContain((await _service.ListFileTransfersAsync()).Transfers, transfer => transfer.TransferId == offer.TransferId);
        }
        finally
        {
            _notifications.ReleaseTransferFailedNotification();
            await TestFiles.DeleteWithRetryAsync(path);
        }
    }

    [Fact]
    public async Task DeletedOutgoingFile_FailsTerminallyInsteadOfWaitingForResume()
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
        var offer = await _service.OfferFileAsync("rift-peer", path, "demo.txt", "text/plain", CancellationToken.None);
        await TestFiles.DeleteWithRetryAsync(path);

        await _service.HandleAcceptReceivedAsync("rift-peer", offer.TransferId, "rift-peer", 262144, CancellationToken.None);
        await WaitForConditionAsync(
            () => _notifications.Notifications.Any(note => note.Method == "rift.onFileTransferFailed"),
            TimeSpan.FromSeconds(1));

        Assert.Equal("Failed", _operationService.GetOperation(offer.OperationId).State);
        Assert.Equal("ProtocolError", _operationService.GetOperation(offer.OperationId).FailureReason);
        Assert.DoesNotContain((await _service.ListFileTransfersAsync()).Transfers, transfer => transfer.TransferId == offer.TransferId);
    }

    [Fact]
    public async Task HandleResumeReceived_UsesPausedOutgoingTransferState()
    {
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer",
            State = TrustState.Trusted,
            Ed25519PublicKey = new byte[32],
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });
        _presenceService.UpdatePeerPresence("rift-peer", "online", null, ["file.transfer"]);
        _transport.FailSecondChunkSendOnce = true;

        var path = CreateTempFile(new string('a', 600000));
        try
        {
            var offer = await _service.OfferFileAsync("rift-peer", path, "demo.txt", "text/plain", CancellationToken.None);
            await _service.HandleAcceptReceivedAsync("rift-peer", offer.TransferId, "rift-peer", 262144, CancellationToken.None);
            await WaitForConditionAsync(
                () => _notifications.Notifications.Any(note => note.Method == "rift.onFileTransferFailed"),
                TimeSpan.FromSeconds(1));

            var sentChunkCountBeforeResume = _transport.SentMessages.Count(sent => sent.Type == "file.chunk");
            await _service.HandleResumeReceivedAsync("rift-peer", offer.TransferId, "rift-peer", 1, 262144, CancellationToken.None);
            await WaitForConditionAsync(
                () => _transport.SentMessages.Count(sent => sent.Type == "file.complete") > 0,
                TimeSpan.FromSeconds(1));

            var resumedChunk = _transport.SentMessages
                .Skip(sentChunkCountBeforeResume)
                .First(sent => sent.Type == "file.chunk");
            Assert.Equal(1, resumedChunk.Payload.GetProperty("chunkIndex").GetInt32());
            Assert.Equal(262144, resumedChunk.Payload.GetProperty("offset").GetInt64());
            await WaitForConditionAsync(
                () => _notifications.Notifications.Any(note => note.Method == "rift.onFileTransferCompleted"),
                TimeSpan.FromSeconds(1));
            Assert.Equal("Done", _operationService.GetOperation(offer.OperationId).State);
            Assert.DoesNotContain((await _service.ListFileTransfersAsync()).Transfers, transfer => transfer.TransferId == offer.TransferId);
        }
        finally
        {
            await TestFiles.DeleteWithRetryAsync(path);
        }
    }

    [Fact]
    public async Task HandleResumeReceived_AfterFinalChunkResendsCompletion()
    {
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer",
            State = TrustState.Trusted,
            Ed25519PublicKey = new byte[32],
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });
        _presenceService.UpdatePeerPresence("rift-peer", "online", null, ["file.transfer"]);
        _transport.FailCompleteSendOnce = true;

        var path = CreateTempFile("hello");
        try
        {
            var offer = await _service.OfferFileAsync("rift-peer", path, "demo.txt", "text/plain", CancellationToken.None);
            await _service.HandleAcceptReceivedAsync("rift-peer", offer.TransferId, "rift-peer", 262144, CancellationToken.None);
            await WaitForConditionAsync(
                () => _notifications.Notifications.Any(note => note.Method == "rift.onFileTransferFailed"),
                TimeSpan.FromSeconds(1));

            await _service.HandleResumeReceivedAsync("rift-peer", offer.TransferId, "rift-peer", 1, 5, CancellationToken.None);
            await WaitForConditionAsync(
                () => _notifications.Notifications.Any(note => note.Method == "rift.onFileTransferCompleted"),
                TimeSpan.FromSeconds(1));

            Assert.Equal(2, _transport.SentMessages.Count(sent => sent.Type == "file.complete"));
            Assert.Equal("Done", _operationService.GetOperation(offer.OperationId).State);
        }
        finally
        {
            await TestFiles.DeleteWithRetryAsync(path);
        }
    }

    [Fact]
    public async Task HandleCancelReceivedAsync_CancelsPausedOutgoingTransfer()
    {
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer",
            State = TrustState.Trusted,
            Ed25519PublicKey = new byte[32],
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });
        _presenceService.UpdatePeerPresence("rift-peer", "online", null, ["file.transfer"]);
        _transport.FailChunkSendOnce = true;

        var path = CreateTempFile(new string('a', 600000));
        try
        {
            var offer = await _service.OfferFileAsync("rift-peer", path, "demo.txt", "text/plain", CancellationToken.None);
            await _service.HandleAcceptReceivedAsync("rift-peer", offer.TransferId, "rift-peer", 262144, CancellationToken.None);
            await WaitForConditionAsync(
                () => _notifications.Notifications.Any(note => note.Method == "rift.onFileTransferFailed"),
                TimeSpan.FromSeconds(1));
            await Task.Delay(50);

            await _service.HandleCancelReceivedAsync("rift-peer", offer.TransferId, "PolicyDenied", "peer cancelled", CancellationToken.None);

            Assert.Equal("Failed", _operationService.GetOperation(offer.OperationId).State);
            Assert.DoesNotContain((await _service.ListFileTransfersAsync()).Transfers, transfer => transfer.TransferId == offer.TransferId);
            var ex = await Assert.ThrowsAsync<FileTransferFailureException>(() =>
                _service.HandleResumeReceivedAsync("rift-peer", offer.TransferId, "rift-peer", 0, 0, CancellationToken.None));
            Assert.Equal("NotFound", ex.FailureReason);
        }
        finally
        {
            await TestFiles.DeleteWithRetryAsync(path);
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
            await TestFiles.DeleteWithRetryAsync(path);
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
    public async Task HandleChunkAndCompleteReceived_RequiresConfirmedDestinationCommit()
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

            Assert.False(File.Exists(destination));
            var pending = Assert.Single((await _service.ListPendingFileCommitsAsync()).Commits);
            Assert.Equal("transfer-store", pending.TransferId);
            Assert.Equal("ready_to_commit", pending.State);
            Assert.True(File.Exists(pending.StagingPath));
            Assert.Contains(_notifications.Notifications, note => note.Method == "rift.onFileTransferReadyToCommit");

            File.Copy(pending.StagingPath, destination);
            var committed = await _service.ConfirmFileCommitAsync(
                "transfer-store",
                destination,
                CancellationToken.None);

            Assert.True(committed.Committed);
            Assert.Equal("hello", await File.ReadAllTextAsync(destination));
            Assert.Empty((await _service.ListPendingFileCommitsAsync()).Commits);
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

    [Fact]
    public async Task AcceptedIncomingTransferWithoutChunks_SendsResumeWhenTrustedSessionReturns()
    {
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer",
            State = TrustState.Trusted,
            Ed25519PublicKey = new byte[32],
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });
        _presenceService.UpdatePeerPresence("rift-peer", "online", null, ["file.transfer"]);

        var bytes = Array.Empty<byte>();
        var sha = Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(bytes));
        const string transferId = "transfer-resume-zero";
        await _service.HandleOfferReceivedAsync(new ReceivedFileOffer
        {
            DeviceId = "rift-peer",
            PayloadSourceDeviceId = "rift-peer",
            TransferId = transferId,
            FileName = "resume.txt",
            MediaType = "text/plain",
            ByteSize = bytes.Length,
            Sha256 = sha,
            ChunkSize = 262144,
            ChunkCount = 1,
            ExpiresInMs = 120000,
            RequiredCapability = "file.transfer"
        }, CancellationToken.None);

        var destination = Path.Combine(Path.GetTempPath(), $"rift-resume-{Guid.NewGuid():N}.txt");
        try
        {
            await _service.AcceptFileOfferAsync(transferId, destination, overwrite: false, CancellationToken.None);

            _transport.RaiseSessionStateChanged(new SessionStateChangedEventArgs("rift-peer", isOnline: true, selectedCapabilities: ["file.transfer"], allowsProtectedTraffic: true));
            await WaitForConditionAsync(() => _transport.SentMessages.Any(sent => sent.Type == "file.resume"), TimeSpan.FromSeconds(1));

            var resume = _transport.SentMessages.Last(sent => sent.Type == "file.resume");
            Assert.Equal(transferId, resume.Payload.GetProperty("transferId").GetString());
            Assert.Equal(0, resume.Payload.GetProperty("nextChunkIndex").GetInt32());
            Assert.Equal(0, resume.Payload.GetProperty("offset").GetInt64());
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
    public async Task FullyReceivedIncomingTransfer_SendsResumeWhenTrustedSessionReturns()
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
        const string transferId = "transfer-resume-complete";
        await _service.HandleOfferReceivedAsync(new ReceivedFileOffer
        {
            DeviceId = "rift-peer",
            PayloadSourceDeviceId = "rift-peer",
            TransferId = transferId,
            FileName = "resume.txt",
            MediaType = "text/plain",
            ByteSize = bytes.Length,
            Sha256 = sha,
            ChunkSize = 262144,
            ChunkCount = 1,
            ExpiresInMs = 120000,
            RequiredCapability = "file.transfer"
        }, CancellationToken.None);

        var destination = Path.Combine(Path.GetTempPath(), $"rift-resume-{Guid.NewGuid():N}.txt");
        try
        {
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

            _transport.RaiseSessionStateChanged(new SessionStateChangedEventArgs("rift-peer", isOnline: true, selectedCapabilities: ["file.transfer"], allowsProtectedTraffic: true));
            await WaitForConditionAsync(() => _transport.SentMessages.Any(sent => sent.Type == "file.resume"), TimeSpan.FromSeconds(1));

            var resume = _transport.SentMessages.Last(sent => sent.Type == "file.resume");
            Assert.Equal(transferId, resume.Payload.GetProperty("transferId").GetString());
            Assert.Equal(1, resume.Payload.GetProperty("nextChunkIndex").GetInt32());
            Assert.Equal(bytes.Length, resume.Payload.GetProperty("offset").GetInt64());
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
    public async Task PartialIncomingTransfer_SendsResumeWhenTrustedSessionReturns()
    {
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer",
            State = TrustState.Trusted,
            Ed25519PublicKey = new byte[32],
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });
        _presenceService.UpdatePeerPresence("rift-peer", "online", null, ["file.transfer"]);

        var bytes = Encoding.UTF8.GetBytes(new string('a', 600000));
        var sha = Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(bytes));
        const string transferId = "transfer-resume";
        await _service.HandleOfferReceivedAsync(new ReceivedFileOffer
        {
            DeviceId = "rift-peer",
            PayloadSourceDeviceId = "rift-peer",
            TransferId = transferId,
            FileName = "resume.txt",
            MediaType = "text/plain",
            ByteSize = bytes.Length,
            Sha256 = sha,
            ChunkSize = 262144,
            ChunkCount = 3,
            ExpiresInMs = 120000,
            RequiredCapability = "file.transfer"
        }, CancellationToken.None);

        var destination = Path.Combine(Path.GetTempPath(), $"rift-resume-{Guid.NewGuid():N}.txt");
        try
        {
            await _service.AcceptFileOfferAsync(transferId, destination, overwrite: false, CancellationToken.None);
            var firstChunk = bytes.AsSpan(0, 262144).ToArray();
            var firstChunkSha = Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(firstChunk));
            await _service.HandleChunkReceivedAsync(
                "rift-peer",
                transferId,
                0,
                0,
                firstChunk.Length,
                firstChunkSha,
                Convert.ToBase64String(firstChunk),
                false,
                CancellationToken.None);

            _transport.RaiseSessionStateChanged(new SessionStateChangedEventArgs("rift-peer", isOnline: true, selectedCapabilities: ["file.transfer"], allowsProtectedTraffic: true));
            await WaitForConditionAsync(() => _transport.SentMessages.Any(sent => sent.Type == "file.resume"), TimeSpan.FromSeconds(1));

            var resume = _transport.SentMessages.Last(sent => sent.Type == "file.resume");
            Assert.Equal(transferId, resume.Payload.GetProperty("transferId").GetString());
            Assert.Equal(1, resume.Payload.GetProperty("nextChunkIndex").GetInt32());
            Assert.Equal(262144, resume.Payload.GetProperty("offset").GetInt64());
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

    private static Task DeleteTempFileAsync(string path) => TestFiles.DeleteWithRetryAsync(path);

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
        private readonly TaskCompletionSource _transferFailedNotificationEntered =
            new(TaskCreationOptions.RunContinuationsAsynchronously);
        private readonly TaskCompletionSource _releaseTransferFailedNotification =
            new(TaskCreationOptions.RunContinuationsAsynchronously);

        public List<(string Method, object Parameters)> Notifications { get; } = [];
        public bool BlockTransferFailedNotification { get; set; }
        public Task TransferFailedNotificationEntered => _transferFailedNotificationEntered.Task;

        public IDisposable RegisterClient(StreamJsonRpc.JsonRpc jsonRpc) => throw new NotSupportedException();

        public async Task NotifyAsync(string method, object parameters, CancellationToken cancellationToken = default)
        {
            Notifications.Add((method, parameters));
            if (BlockTransferFailedNotification && method == "rift.onFileTransferFailed")
            {
                _transferFailedNotificationEntered.TrySetResult();
                await _releaseTransferFailedNotification.Task.WaitAsync(cancellationToken);
            }
        }

        public void ReleaseTransferFailedNotification()
        {
            _releaseTransferFailedNotification.TrySetResult();
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

        public event EventHandler<SessionStateChangedEventArgs>? SessionStateChanged;

        public List<(string PeerDeviceId, string Type, JsonElement Payload)> SentMessages { get; } = [];
        public List<(string Host, int Port)> ConnectAttempts { get; } = [];
        public List<string> DisconnectedPeers { get; } = [];
        public Queue<Exception> ConnectExceptions { get; } = new();
        public bool BlockChunkSends { get; set; }
        public bool FailChunkSendOnce { get; set; }
        public bool FailSecondChunkSendOnce { get; set; }
        public bool FailCompleteSendOnce { get; set; }
        public int BlockedChunkSendCount { get; private set; }
        public int ChunkSendCount { get; private set; }
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
            if (string.Equals(type, "file.chunk", StringComparison.Ordinal))
            {
                ChunkSendCount++;
                if (FailChunkSendOnce)
                {
                    FailChunkSendOnce = false;
                    throw new IOException("simulated broken pipe");
                }
                if (FailSecondChunkSendOnce && ChunkSendCount == 2)
                {
                    FailSecondChunkSendOnce = false;
                    throw new IOException("simulated broken pipe");
                }
            }
            if (BlockChunkSends && string.Equals(type, "file.chunk", StringComparison.Ordinal))
            {
                BlockedChunkSendCount++;
                return _releaseBlockedChunkSends.Task.WaitAsync(cancellationToken);
            }
            if (FailCompleteSendOnce && string.Equals(type, "file.complete", StringComparison.Ordinal))
            {
                FailCompleteSendOnce = false;
                throw new IOException("simulated completion send failure");
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

        public void RaiseSessionStateChanged(SessionStateChangedEventArgs args)
        {
            SessionStateChanged?.Invoke(this, args);
        }
    }
}
