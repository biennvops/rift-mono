using Microsoft.Data.Sqlite;
using Rift.Daemon.Core;
using Rift.Daemon.Core.Interfaces;

namespace Rift.Daemon.Tests.Core;

public sealed class SendQueueServiceTests
{
    private readonly InMemoryTrustStore _trustStore = new();

    [Fact]
    public async Task EnqueueFileSendAsync_WithoutTarget_StartsWaitingForTarget()
    {
        var service = new SendQueueService(_trustStore, null);
        var path = CreateTempFile("hello");
        try
        {
            var result = await service.EnqueueFileSendAsync(path, "demo.txt", "text/plain", null, "picker", CancellationToken.None);
            var listed = await service.ListSendQueueAsync(CancellationToken.None);

            Assert.Equal("waiting_for_target", result.Status);
            Assert.Contains(listed.Items, item => item.QueueItemId == result.QueueItemId && item.Status == "waiting_for_target");
        }
        finally
        {
            await TestFiles.DeleteWithRetryAsync(path);
        }
    }

    [Fact]
    public async Task AssignSendQueueTargetAsync_MovesItemToQueued()
    {
        var service = new SendQueueService(_trustStore, null);
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer",
            State = TrustState.Trusted,
            Ed25519PublicKey = new byte[32],
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });
        var path = CreateTempFile("hello");
        try
        {
            var enqueued = await service.EnqueueFileSendAsync(path, "demo.txt", "text/plain", null, "picker", CancellationToken.None);
            var updated = await service.AssignSendQueueTargetAsync(enqueued.QueueItemId, "rift-peer", CancellationToken.None);

            Assert.Equal("queued", updated.Status);
            Assert.Equal("rift-peer", updated.TargetDeviceId);
        }
        finally
        {
            await TestFiles.DeleteWithRetryAsync(path);
        }
    }

    [Fact]
    public async Task RetrySendQueueItemAsync_KeepsWaitingForTargetWhenTargetMissing()
    {
        var service = new SendQueueService(_trustStore, null);
        var path = CreateTempFile("hello");
        try
        {
            var enqueued = await service.EnqueueFileSendAsync(path, "demo.txt", "text/plain", null, "picker", CancellationToken.None);
            var retried = await service.RetrySendQueueItemAsync(enqueued.QueueItemId, CancellationToken.None);

            Assert.Equal("waiting_for_target", retried.Status);
        }
        finally
        {
            await TestFiles.DeleteWithRetryAsync(path);
        }
    }

    [Fact]
    public async Task EnqueueFileSendAsync_WithTarget_DispatchesImmediately()
    {
        var fileTransfer = new FakeFileTransferService();
        var transport = new FakeTransport();
        var service = new SendQueueService(_trustStore, null, fileTransfer, transport);
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer",
            State = TrustState.Trusted,
            Ed25519PublicKey = new byte[32],
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });
        var path = CreateTempFile("hello");
        try
        {
            var result = await service.EnqueueFileSendAsync(path, "demo.txt", "text/plain", "rift-peer", "picker", CancellationToken.None);
            var item = await service.GetSendQueueItemAsync(result.QueueItemId, CancellationToken.None);

            Assert.Equal("dispatching", result.Status);
            Assert.Equal("dispatching", item.Status);
            Assert.Equal("rift-peer", fileTransfer.LastOfferTargetDeviceId);
            Assert.NotNull(item.CurrentOperationId);
            Assert.NotNull(item.LastTransferId);
        }
        finally
        {
            await TestFiles.DeleteWithRetryAsync(path);
        }
    }

    [Fact]
    public async Task TransferUpdated_Done_MarksQueueItemSent()
    {
        var fileTransfer = new FakeFileTransferService();
        var service = new SendQueueService(_trustStore, null, fileTransfer, new FakeTransport());
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer",
            State = TrustState.Trusted,
            Ed25519PublicKey = new byte[32],
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });
        var path = CreateTempFile("hello");
        try
        {
            var result = await service.EnqueueFileSendAsync(path, "demo.txt", "text/plain", "rift-peer", "picker", CancellationToken.None);
            var queued = await service.GetSendQueueItemAsync(result.QueueItemId, CancellationToken.None);
            fileTransfer.RaiseTransferUpdated(new FileTransferLifecycleEventArgs
            {
                TransferId = queued.LastTransferId!,
                OperationId = queued.CurrentOperationId!,
                Direction = "outgoing",
                PeerDeviceId = "rift-peer",
                FileName = "demo.txt",
                ByteSize = 5,
                BytesTransferred = 5,
                State = "done"
            });

            var updated = await service.GetSendQueueItemAsync(result.QueueItemId, CancellationToken.None);
            Assert.Equal("sent", updated.Status);
        }
        finally
        {
            await TestFiles.DeleteWithRetryAsync(path);
        }
    }

    [Fact]
    public async Task RecoverableFailure_WaitsForPeer_AndRetriesOnReconnect()
    {
        var fileTransfer = new FakeFileTransferService
        {
            OfferException = new FileTransferFailureException("PeerUnreachable", -32000, "Peer offline")
        };
        var transport = new FakeTransport();
        var service = new SendQueueService(_trustStore, null, fileTransfer, transport);
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer",
            State = TrustState.Trusted,
            Ed25519PublicKey = new byte[32],
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });
        var path = CreateTempFile("hello");
        try
        {
            var result = await service.EnqueueFileSendAsync(path, "demo.txt", "text/plain", "rift-peer", "picker", CancellationToken.None);
            var failed = await service.GetSendQueueItemAsync(result.QueueItemId, CancellationToken.None);
            Assert.Equal("waiting_for_peer", failed.Status);

            fileTransfer.OfferException = null;
            transport.RaiseSessionStateChanged(new SessionStateChangedEventArgs("rift-peer", isOnline: true, selectedCapabilities: ["file.transfer"], allowsProtectedTraffic: true));
            await WaitForStatusAsync(service, result.QueueItemId, "dispatching");

            var retried = await service.GetSendQueueItemAsync(result.QueueItemId, CancellationToken.None);
            Assert.Equal("dispatching", retried.Status);
            Assert.Equal(2, fileTransfer.OfferCallCount);
        }
        finally
        {
            await TestFiles.DeleteWithRetryAsync(path);
        }
    }

    [Fact]
    public async Task RecoverableFailure_DoesNotRetryOnUnprotectedReconnect()
    {
        var fileTransfer = new FakeFileTransferService
        {
            OfferException = new FileTransferFailureException("PeerUnreachable", -32000, "Peer offline")
        };
        var transport = new FakeTransport();
        var service = new SendQueueService(_trustStore, null, fileTransfer, transport);
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer",
            State = TrustState.Trusted,
            Ed25519PublicKey = new byte[32],
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });
        var path = CreateTempFile("hello");
        try
        {
            var result = await service.EnqueueFileSendAsync(path, "demo.txt", "text/plain", "rift-peer", "picker", CancellationToken.None);
            var failed = await service.GetSendQueueItemAsync(result.QueueItemId, CancellationToken.None);
            Assert.Equal("waiting_for_peer", failed.Status);

            fileTransfer.OfferException = null;
            transport.RaiseSessionStateChanged(new SessionStateChangedEventArgs("rift-peer", isOnline: true, selectedCapabilities: ["file.transfer"], allowsProtectedTraffic: false));
            await Task.Delay(50);

            var unchanged = await service.GetSendQueueItemAsync(result.QueueItemId, CancellationToken.None);
            Assert.Equal("waiting_for_peer", unchanged.Status);
            Assert.Equal(1, fileTransfer.OfferCallCount);
        }
        finally
        {
            await TestFiles.DeleteWithRetryAsync(path);
        }
    }

    [Fact]
    public async Task ResumableWaitingForPeer_DoesNotCreateNewOfferOnReconnect()
    {
        var fileTransfer = new FakeFileTransferService();
        var transport = new FakeTransport();
        var service = new SendQueueService(_trustStore, null, fileTransfer, transport);
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer",
            State = TrustState.Trusted,
            Ed25519PublicKey = new byte[32],
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });
        var path = CreateTempFile("hello");
        try
        {
            var result = await service.EnqueueFileSendAsync(path, "demo.txt", "text/plain", "rift-peer", "picker", CancellationToken.None);
            fileTransfer.RaiseTransferUpdated(new FileTransferLifecycleEventArgs
            {
                TransferId = "transfer-1",
                OperationId = "operation-1",
                Direction = "outgoing",
                PeerDeviceId = "rift-peer",
                FileName = "demo.txt",
                ByteSize = 5,
                State = "failed",
                FailureReason = "ConnectionLost",
                Message = "socket reset"
            });

            var waiting = await service.GetSendQueueItemAsync(result.QueueItemId, CancellationToken.None);
            Assert.Equal("waiting_for_peer", waiting.Status);
            Assert.Equal("transfer-1", waiting.LastTransferId);
            Assert.Equal("operation-1", waiting.CurrentOperationId);
            Assert.Equal(1, fileTransfer.OfferCallCount);

            transport.RaiseSessionStateChanged(new SessionStateChangedEventArgs("rift-peer", isOnline: true, selectedCapabilities: ["file.transfer"], allowsProtectedTraffic: true));
            await Task.Delay(50);

            var unchanged = await service.GetSendQueueItemAsync(result.QueueItemId, CancellationToken.None);
            Assert.Equal("waiting_for_peer", unchanged.Status);
            Assert.Equal("transfer-1", unchanged.LastTransferId);
            Assert.Equal(1, fileTransfer.OfferCallCount);
        }
        finally
        {
            await TestFiles.DeleteWithRetryAsync(path);
        }
    }

    [Fact]
    public async Task TerminalPayloadTooLargeFailure_DoesNotWaitForPeer()
    {
        var fileTransfer = new FakeFileTransferService
        {
            OfferException = new FileTransferFailureException("PayloadTooLarge", -32007, "Incoming file offer exceeded the maximum supported size.")
        };
        var transport = new FakeTransport();
        var service = new SendQueueService(_trustStore, null, fileTransfer, transport);
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer",
            State = TrustState.Trusted,
            Ed25519PublicKey = new byte[32],
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });
        var path = CreateTempFile("hello");
        try
        {
            var result = await service.EnqueueFileSendAsync(path, "demo.txt", "text/plain", "rift-peer", "picker", CancellationToken.None);
            var failed = await service.GetSendQueueItemAsync(result.QueueItemId, CancellationToken.None);
            Assert.Equal("failed", failed.Status);
            Assert.Equal("PayloadTooLarge", failed.FailureReason);

            fileTransfer.OfferException = null;
            transport.RaiseSessionStateChanged(new SessionStateChangedEventArgs("rift-peer", isOnline: true, selectedCapabilities: ["file.transfer"], allowsProtectedTraffic: true));
            await Task.Delay(50);

            var unchanged = await service.GetSendQueueItemAsync(result.QueueItemId, CancellationToken.None);
            Assert.Equal("failed", unchanged.Status);
            Assert.Equal(1, fileTransfer.OfferCallCount);
        }
        finally
        {
            await TestFiles.DeleteWithRetryAsync(path);
        }
    }

    [Fact]
    public async Task Service_RestoresPersistedQueueItems_OnRestart()
    {
        var databasePath = Path.Combine(Path.GetTempPath(), $"rift-send-queue-service-{Guid.NewGuid():N}.db");
        var databaseContext = new Rift.Daemon.Core.Data.DatabaseContext(databasePath);
        databaseContext.Initialize();
        var store = new Rift.Daemon.Core.Data.SqliteSendQueueStore(databaseContext);

        var path = CreateTempFile("hello");
        try
        {
            var first = new SendQueueService(_trustStore, null, null, null, store);
            var created = await first.EnqueueFileSendAsync(path, "demo.txt", "text/plain", null, "picker", CancellationToken.None);

            var second = new SendQueueService(_trustStore, null, null, null, store);
            var restored = await second.GetSendQueueItemAsync(created.QueueItemId, CancellationToken.None);

            Assert.Equal("waiting_for_target", restored.Status);
            Assert.Equal(path, restored.LocalPath);
            Assert.Equal("demo.txt", restored.FileName);
        }
        finally
        {
            await TestFiles.DeleteWithRetryAsync(path);
            SqliteConnection.ClearAllPools();
            if (File.Exists(databasePath))
            {
                File.Delete(databasePath);
            }
        }
    }

    [Fact]
    public async Task Service_RestoresWaitingForPeerItem_AndRetriesWhenPeerReturnsOnline()
    {
        var databasePath = Path.Combine(Path.GetTempPath(), $"rift-send-queue-recover-{Guid.NewGuid():N}.db");
        var databaseContext = new Rift.Daemon.Core.Data.DatabaseContext(databasePath);
        databaseContext.Initialize();
        var store = new Rift.Daemon.Core.Data.SqliteSendQueueStore(databaseContext);
        var transport = new FakeTransport();
        var fileTransfer = new FakeFileTransferService();

        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer",
            State = TrustState.Trusted,
            Ed25519PublicKey = new byte[32],
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });

        store.UpsertItem(new SendQueueItemInfo
        {
            QueueItemId = "queue-1",
            Status = "waiting_for_peer",
            TargetDeviceId = "rift-peer",
            LocalPath = CreateTempFile("hello"),
            FileName = "demo.txt",
            MediaType = "text/plain",
            ByteSize = 5,
            CurrentOperationId = null,
            LastTransferId = null,
            FailureReason = "PeerUnreachable",
            FailureMessage = "offline",
            CreatedAt = DateTimeOffset.UtcNow.ToString("O"),
            UpdatedAt = DateTimeOffset.UtcNow.ToString("O"),
            Origin = "picker"
        });

        try
        {
            var service = new SendQueueService(_trustStore, null, fileTransfer, transport, store);

            var restored = await service.GetSendQueueItemAsync("queue-1", CancellationToken.None);
            Assert.Equal("waiting_for_peer", restored.Status);

            transport.RaiseSessionStateChanged(new SessionStateChangedEventArgs("rift-peer", isOnline: true, selectedCapabilities: ["file.transfer"], allowsProtectedTraffic: true));
            await WaitForStatusAsync(service, "queue-1", "dispatching");

            var retried = await service.GetSendQueueItemAsync("queue-1", CancellationToken.None);
            Assert.Equal("dispatching", retried.Status);
            Assert.Equal(1, fileTransfer.OfferCallCount);
        }
        finally
        {
            var item = store.ListItems().Single();
            File.Delete(item.LocalPath);
            await DeleteDatabaseAsync(databasePath);
        }
    }

    [Fact]
    public async Task Service_RestoresDispatchingItem_AsWaitingForPeerAfterRestart()
    {
        var databasePath = Path.Combine(Path.GetTempPath(), $"rift-send-queue-dispatching-{Guid.NewGuid():N}.db");
        var databaseContext = new Rift.Daemon.Core.Data.DatabaseContext(databasePath);
        databaseContext.Initialize();
        var store = new Rift.Daemon.Core.Data.SqliteSendQueueStore(databaseContext);
        var localPath = CreateTempFile("hello");

        store.UpsertItem(new SendQueueItemInfo
        {
            QueueItemId = "queue-1",
            Status = "dispatching",
            TargetDeviceId = "rift-peer",
            LocalPath = localPath,
            FileName = "demo.txt",
            MediaType = "text/plain",
            ByteSize = 5,
            CurrentOperationId = "operation-1",
            LastTransferId = "transfer-1",
            FailureReason = null,
            FailureMessage = null,
            CreatedAt = DateTimeOffset.UtcNow.ToString("O"),
            UpdatedAt = DateTimeOffset.UtcNow.ToString("O"),
            Origin = "picker"
        });

        try
        {
            var service = new SendQueueService(_trustStore, null, null, null, store);
            var restored = await service.GetSendQueueItemAsync("queue-1", CancellationToken.None);

            Assert.Equal("waiting_for_peer", restored.Status);
            Assert.Equal("DaemonRestarted", restored.FailureReason);
            Assert.Null(restored.CurrentOperationId);
            Assert.Null(restored.LastTransferId);
        }
        finally
        {
            await TestFiles.DeleteWithRetryAsync(localPath);
            SqliteConnection.ClearAllPools();
            if (File.Exists(databasePath))
            {
                File.Delete(databasePath);
            }
        }
    }

    [Fact]
    public async Task SessionOnline_SerializesMultipleItemsForSamePeer()
    {
        _trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = "rift-peer",
            State = TrustState.Trusted,
            Ed25519PublicKey = new byte[32],
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });

        var fileTransfer = new ConcurrencyTrackingFileTransferService();
        var transport = new FakeTransport();
        var service = new SendQueueService(_trustStore, null, fileTransfer, transport);

        var firstPath = CreateTempFile("one");
        var secondPath = CreateTempFile("two");
        var thirdPath = CreateTempFile("three");
        try
        {
            await service.EnqueueFileSendAsync(firstPath, "one.txt", "text/plain", "rift-peer", "picker", CancellationToken.None);
            await service.EnqueueFileSendAsync(secondPath, "two.txt", "text/plain", "rift-peer", "picker", CancellationToken.None);
            await service.EnqueueFileSendAsync(thirdPath, "three.txt", "text/plain", "rift-peer", "picker", CancellationToken.None);

            // All three are dispatched immediately on EnqueueFileSendAsync.
            // Drive an extra reconnect to confirm we still serialize.
            transport.RaiseSessionStateChanged(new SessionStateChangedEventArgs(
                "rift-peer",
                isOnline: true,
                selectedCapabilities: ["file.transfer"],
                allowsProtectedTraffic: true));
            await Task.Delay(100);

            Assert.True(fileTransfer.MaxConcurrentCalls <= 1,
                $"Per-peer dispatch must be serialized, but {fileTransfer.MaxConcurrentCalls} OfferFileAsync calls overlapped.");
            Assert.True(fileTransfer.OfferCallCount >= 3,
                $"Expected at least 3 OfferFileAsync calls, saw {fileTransfer.OfferCallCount}.");
        }
        finally
        {
            await TestFiles.DeleteWithRetryAsync(firstPath);
            await TestFiles.DeleteWithRetryAsync(secondPath);
            await TestFiles.DeleteWithRetryAsync(thirdPath);
        }
    }

    private static string CreateTempFile(string content)
    {
        var path = Path.Combine(Path.GetTempPath(), $"rift-send-queue-{Guid.NewGuid():N}.txt");
        File.WriteAllText(path, content);
        return path;
    }

    // Background dispatch can briefly reopen store connections after
    // ClearAllPools, which keeps the file locked on Windows.
    private static async Task DeleteDatabaseAsync(string databasePath)
    {
        for (var attempt = 0; ; attempt++)
        {
            SqliteConnection.ClearAllPools();
            try
            {
                if (File.Exists(databasePath))
                {
                    File.Delete(databasePath);
                }
                return;
            }
            catch (IOException) when (attempt < 50)
            {
                await Task.Delay(20);
            }
        }
    }

    // Reconnect-triggered retries dispatch on a background task, so status
    // assertions must poll rather than rely on a fixed delay.
    private static async Task WaitForStatusAsync(SendQueueService service, string queueItemId, string expectedStatus)
    {
        var deadline = DateTime.UtcNow.AddSeconds(5);
        while (true)
        {
            var item = await service.GetSendQueueItemAsync(queueItemId, CancellationToken.None);
            if (item.Status == expectedStatus)
            {
                return;
            }

            if (DateTime.UtcNow >= deadline)
            {
                throw new TimeoutException(
                    $"Queue item {queueItemId} did not reach status '{expectedStatus}' (last: '{item.Status}').");
            }

            await Task.Delay(20);
        }
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

    private sealed class FakeFileTransferService : IFileTransferService
    {
        public event EventHandler<FileTransferLifecycleEventArgs>? TransferUpdated;

        public Exception? OfferException { get; set; }

        public int OfferCallCount { get; private set; }

        public string? LastOfferTargetDeviceId { get; private set; }

        public Task<OfferFileResult> OfferFileAsync(string targetDeviceId, string localPath, string? fileName, string? mediaType, CancellationToken cancellationToken)
        {
            OfferCallCount += 1;
            LastOfferTargetDeviceId = targetDeviceId;
            if (OfferException is not null)
            {
                throw OfferException;
            }

            return Task.FromResult(new OfferFileResult
            {
                TransferId = $"transfer-{OfferCallCount}",
                OperationId = $"operation-{OfferCallCount}",
                TargetDeviceId = targetDeviceId,
                FileName = fileName ?? Path.GetFileName(localPath),
                ByteSize = new FileInfo(localPath).Length
            });
        }

        public void RaiseTransferUpdated(FileTransferLifecycleEventArgs args)
        {
            TransferUpdated?.Invoke(this, args);
        }

        public Task<ListIncomingFileOffersResult> ListIncomingFileOffersAsync() => throw new NotSupportedException();
        public Task<AcceptFileOfferResult> AcceptFileOfferAsync(string transferId, string destinationPath, bool overwrite, CancellationToken cancellationToken) => throw new NotSupportedException();
        public Task<RejectFileOfferResult> RejectFileOfferAsync(string transferId, string failureReason, string? message, CancellationToken cancellationToken) => throw new NotSupportedException();
        public Task<ListFileTransfersResult> ListFileTransfersAsync() => throw new NotSupportedException();
        public Task<FileTransferInfo> CancelTransferAsync(string transferId, CancellationToken cancellationToken) => throw new NotSupportedException();
        public Task HandleOfferReceivedAsync(ReceivedFileOffer offer, CancellationToken cancellationToken) => throw new NotSupportedException();
        public Task HandleAcceptReceivedAsync(string deviceId, string transferId, string receivingDeviceId, int? chunkSize, CancellationToken cancellationToken) => throw new NotSupportedException();
        public Task HandleRejectReceivedAsync(string deviceId, string transferId, string failureReason, string? message, CancellationToken cancellationToken) => throw new NotSupportedException();
        public Task HandleChunkReceivedAsync(string deviceId, string transferId, int chunkIndex, long offset, int byteSize, string chunkSha256, string contentBase64, bool isLastChunk, CancellationToken cancellationToken) => throw new NotSupportedException();
        public Task HandleCompleteReceivedAsync(string deviceId, string transferId, long byteSize, string sha256, int chunkCount, CancellationToken cancellationToken) => throw new NotSupportedException();
        public Task HandleCancelReceivedAsync(string deviceId, string transferId, string failureReason, string? message, CancellationToken cancellationToken) => throw new NotSupportedException();
        public Task HandleResumeReceivedAsync(string deviceId, string transferId, string receivingDeviceId, int nextChunkIndex, long offset, CancellationToken cancellationToken) => throw new NotSupportedException();
    }

    private sealed class ConcurrencyTrackingFileTransferService : IFileTransferService
    {
        public event EventHandler<FileTransferLifecycleEventArgs>? TransferUpdated;

        private int _inFlight;
        private int _maxInFlight;
        private int _callCount;

        public int MaxConcurrentCalls => _maxInFlight;
        public int OfferCallCount => _callCount;

        public Task<OfferFileResult> OfferFileAsync(string targetDeviceId, string localPath, string? fileName, string? mediaType, CancellationToken cancellationToken)
        {
            var current = Interlocked.Increment(ref _inFlight);
            InterlockedMax(ref _maxInFlight, current);
            return Task.Run(async () =>
            {
                // Give the dispatcher a chance to start another dispatch if
                // it (incorrectly) does not await the previous call.
                await Task.Delay(20, cancellationToken).ConfigureAwait(false);
                Interlocked.Decrement(ref _inFlight);
                var n = Interlocked.Increment(ref _callCount);
                return new OfferFileResult
                {
                    TransferId = $"transfer-{n}",
                    OperationId = $"operation-{n}",
                    TargetDeviceId = targetDeviceId,
                    FileName = fileName ?? Path.GetFileName(localPath),
                    ByteSize = new FileInfo(localPath).Length
                };
            });
        }

        public void RaiseTransferUpdated(FileTransferLifecycleEventArgs args)
        {
            TransferUpdated?.Invoke(this, args);
        }

        private static void InterlockedMax(ref int location, int value)
        {
            int snapshot;
            do
            {
                snapshot = Volatile.Read(ref location);
                if (value <= snapshot)
                {
                    return;
                }
            } while (Interlocked.CompareExchange(ref location, value, snapshot) != snapshot);
        }

        public Task<ListIncomingFileOffersResult> ListIncomingFileOffersAsync() => throw new NotSupportedException();
        public Task<AcceptFileOfferResult> AcceptFileOfferAsync(string transferId, string destinationPath, bool overwrite, CancellationToken cancellationToken) => throw new NotSupportedException();
        public Task<RejectFileOfferResult> RejectFileOfferAsync(string transferId, string failureReason, string? message, CancellationToken cancellationToken) => throw new NotSupportedException();
        public Task<ListFileTransfersResult> ListFileTransfersAsync() => throw new NotSupportedException();
        public Task<FileTransferInfo> CancelTransferAsync(string transferId, CancellationToken cancellationToken) => throw new NotSupportedException();
        public Task HandleOfferReceivedAsync(ReceivedFileOffer offer, CancellationToken cancellationToken) => throw new NotSupportedException();
        public Task HandleAcceptReceivedAsync(string deviceId, string transferId, string receivingDeviceId, int? chunkSize, CancellationToken cancellationToken) => throw new NotSupportedException();
        public Task HandleRejectReceivedAsync(string deviceId, string transferId, string failureReason, string? message, CancellationToken cancellationToken) => throw new NotSupportedException();
        public Task HandleChunkReceivedAsync(string deviceId, string transferId, int chunkIndex, long offset, int byteSize, string chunkSha256, string contentBase64, bool isLastChunk, CancellationToken cancellationToken) => throw new NotSupportedException();
        public Task HandleCompleteReceivedAsync(string deviceId, string transferId, long byteSize, string sha256, int chunkCount, CancellationToken cancellationToken) => throw new NotSupportedException();
        public Task HandleCancelReceivedAsync(string deviceId, string transferId, string failureReason, string? message, CancellationToken cancellationToken) => throw new NotSupportedException();
        public Task HandleResumeReceivedAsync(string deviceId, string transferId, string receivingDeviceId, int nextChunkIndex, long offset, CancellationToken cancellationToken) => throw new NotSupportedException();
    }

    private sealed class FakeTransport : ITransport
    {
        public event EventHandler<MessageReceivedEventArgs>? MessageReceived
        {
            add { }
            remove { }
        }

        public event EventHandler<SessionStateChangedEventArgs>? SessionStateChanged;

        public void RaiseSessionStateChanged(SessionStateChangedEventArgs args)
        {
            SessionStateChanged?.Invoke(this, args);
        }

        public Task StartListeningAsync(CancellationToken cancellationToken) => throw new NotSupportedException();
        public Task ConnectToPeerAsync(string host, int port, CancellationToken cancellationToken) => throw new NotSupportedException();
        public Task<string> ConnectToPeerWithIdentityAsync(string host, int port, CancellationToken cancellationToken) => throw new NotSupportedException();
        public bool HasActiveSession(string peerDeviceId) => false;
        public bool HasProtectedSession(string peerDeviceId) => false;
        public void RefreshSessionAuthorization(string peerDeviceId) { }
        public PeerSessionEndpoint? GetPeerSessionEndpoint(string peerDeviceId) => null;
        public Task SendAsync(string peerDeviceId, ReadOnlyMemory<byte> frameBody, CancellationToken cancellationToken) => throw new NotSupportedException();
        public Task DisconnectPeerAsync(string peerDeviceId, CancellationToken cancellationToken) => throw new NotSupportedException();
    }
}
