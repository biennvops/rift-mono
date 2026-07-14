using System.Collections.Concurrent;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;
using Rift.Daemon.Core.Interfaces;

namespace Rift.Daemon.Core;

public sealed class FileTransferService : IFileTransferService
{
    private const string RequiredCapability = "file.transfer";
    private const int DefaultChunkSize = 256 * 1024;
    private const int MaxChunkSize = 4 * 1024 * 1024;
    private const int DefaultOfferExpiryMs = 300000;
    private const long MaxIncomingOfferByteSize = 32L * 1024 * 1024;
    private static readonly TimeSpan TrustedReconnectTimeout = TimeSpan.FromSeconds(3);

    private readonly ITransport _transport;
    private readonly ITrustStore _trustStore;
    private readonly IDiscoveryCoordinator _discoveryCoordinator;
    private readonly IPresenceService _presenceService;
    private readonly IIdentityManager _identityManager;
    private readonly ISecurityEventLog _securityEventLog;
    private readonly IOperationService _operationService;
    private readonly IIpcNotificationService? _ipcNotificationService;
    private readonly ILogger<FileTransferService> _logger;
    private readonly TimeProvider _timeProvider = TimeProvider.System;

    private readonly ConcurrentDictionary<string, RemoteFileOfferState> _remoteOffers = new(StringComparer.Ordinal);
    private readonly ConcurrentDictionary<string, OutgoingTransferState> _outgoingTransfers = new(StringComparer.Ordinal);
    private readonly ConcurrentDictionary<string, IncomingTransferState> _incomingTransfers = new(StringComparer.Ordinal);
    private readonly ConcurrentDictionary<string, Task> _pendingTrustedReconnects = new(StringComparer.Ordinal);

    public FileTransferService(
        ITransport transport,
        ITrustStore trustStore,
        IDiscoveryCoordinator discoveryCoordinator,
        IPresenceService presenceService,
        IIdentityManager identityManager,
        ISecurityEventLog securityEventLog,
        IOperationService operationService,
        IIpcNotificationService? ipcNotificationService = null,
        ILogger<FileTransferService>? logger = null)
    {
        _transport = transport;
        _trustStore = trustStore;
        _discoveryCoordinator = discoveryCoordinator;
        _presenceService = presenceService;
        _identityManager = identityManager;
        _securityEventLog = securityEventLog;
        _operationService = operationService;
        _ipcNotificationService = ipcNotificationService;
        _logger = logger ?? NullLogger<FileTransferService>.Instance;
    }

    public async Task<OfferFileResult> OfferFileAsync(
        string targetDeviceId,
        string localPath,
        string? fileName,
        string? mediaType,
        CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(targetDeviceId))
        {
            throw new FileTransferFailureException("NotFound", -32009, "A target device is required.");
        }

        if (string.IsNullOrWhiteSpace(localPath) || !File.Exists(localPath))
        {
            throw new FileTransferFailureException("NotFound", -32009, $"Local file '{localPath}' was not found.");
        }

        EnsurePeerCanUseFileTransfer(targetDeviceId, RequiredCapability);

        var resolvedFileName = string.IsNullOrWhiteSpace(fileName)
            ? Path.GetFileName(localPath)
            : fileName.Trim();
        if (resolvedFileName.Length == 0)
        {
            throw new FileTransferFailureException("ProtocolError", -32001, "A file name is required.");
        }

        var resolvedMediaType = string.IsNullOrWhiteSpace(mediaType)
            ? "application/octet-stream"
            : mediaType.Trim();

        var fileInfo = new FileInfo(localPath);
        if (fileInfo.Length < 0)
        {
            throw new FileTransferFailureException("ProtocolError", -32001, "Invalid file size.");
        }

        var sha256 = ComputeFileSha256(localPath);
        var transferId = Guid.NewGuid().ToString("D");
        var operationId = Guid.NewGuid().ToString("D");
        var chunkCount = ComputeChunkCount(fileInfo.Length, DefaultChunkSize);

        _operationService.CreateOperation(operationId, "file.send", _identityManager.GetDeviceId(), targetDeviceId);
        _operationService.TransitionOperation(operationId, OperationState.Pending, details: new Dictionary<string, object?>
        {
            ["transferId"] = transferId,
            ["fileName"] = resolvedFileName,
            ["byteSize"] = fileInfo.Length
        });

        var transfer = new OutgoingTransferState
        {
            TransferId = transferId,
            OperationId = operationId,
            TargetDeviceId = targetDeviceId,
            LocalPath = localPath,
            FileName = resolvedFileName,
            MediaType = resolvedMediaType,
            ByteSize = fileInfo.Length,
            Sha256 = sha256,
            ChunkSize = DefaultChunkSize,
            ChunkCount = chunkCount,
            ExpiresAt = _timeProvider.GetUtcNow().AddMilliseconds(DefaultOfferExpiryMs),
            SendCancellation = new CancellationTokenSource()
        };
        _outgoingTransfers[transferId] = transfer;

        var envelope = new
        {
            rift = "0.1-draft",
            type = "file.offer",
            messageId = Guid.NewGuid().ToString("D"),
            sourceDeviceId = _identityManager.GetDeviceId(),
            payload = new
            {
                transferId,
                fileName = resolvedFileName,
                mediaType = resolvedMediaType,
                byteSize = fileInfo.Length,
                sha256,
                chunkSize = DefaultChunkSize,
                chunkCount,
                expiresInMs = DefaultOfferExpiryMs,
                sourceDeviceId = _identityManager.GetDeviceId(),
                requiredCapability = RequiredCapability
            }
        };

        try
        {
            await SendProtectedMessageAsync(targetDeviceId, EncodeEnvelope(envelope), cancellationToken).ConfigureAwait(false);
            _operationService.TransitionOperation(operationId, OperationState.Dispatched);
        }
        catch (Exception ex) when (ex is FileTransferFailureException or InvalidOperationException or UnauthorizedAccessException)
        {
            _operationService.TransitionOperation(operationId, OperationState.Failed, failureReason: "PeerUnreachable");
            throw;
        }

        return new OfferFileResult
        {
            TransferId = transferId,
            OperationId = operationId,
            TargetDeviceId = targetDeviceId,
            FileName = resolvedFileName,
            ByteSize = fileInfo.Length,
            ChunkSize = DefaultChunkSize,
            ChunkCount = chunkCount
        };
    }

    public async Task<ListIncomingFileOffersResult> ListIncomingFileOffersAsync()
    {
        await PruneExpiredOffersAsync().ConfigureAwait(false);

        var offers = _remoteOffers.Values
            .OrderBy(offer => offer.ExpiresAt)
            .Select(offer => new IncomingFileOfferInfo
            {
                TransferId = offer.TransferId,
                SourceDeviceId = offer.SourceDeviceId,
                FileName = offer.FileName,
                MediaType = offer.MediaType,
                ByteSize = offer.ByteSize,
                Sha256 = offer.Sha256,
                ChunkSize = offer.ChunkSize,
                ChunkCount = offer.ChunkCount,
                ExpiresAt = offer.ExpiresAt.ToString("O")
            })
            .ToArray();

        return new ListIncomingFileOffersResult
        {
            Offers = offers
        };
    }

    public async Task<AcceptFileOfferResult> AcceptFileOfferAsync(
        string transferId,
        string destinationPath,
        bool overwrite,
        CancellationToken cancellationToken)
    {
        await PruneExpiredOffersAsync().ConfigureAwait(false);

        if (!_remoteOffers.TryGetValue(transferId, out var offer))
        {
            throw new FileTransferFailureException("NotFound", -32009, $"Incoming file offer '{transferId}' was not found.");
        }

        EnsurePeerCanUseFileTransfer(offer.SourceDeviceId, RequiredCapability);

        if (string.IsNullOrWhiteSpace(destinationPath))
        {
            throw new FileTransferFailureException("PolicyDenied", -32010, "A destination path is required to accept a file.");
        }

        var fullDestinationPath = Path.GetFullPath(destinationPath);
        var destinationDirectory = Path.GetDirectoryName(fullDestinationPath);
        if (string.IsNullOrWhiteSpace(destinationDirectory))
        {
            throw new FileTransferFailureException("StorageUnavailable", -32001, "Destination path must include a parent directory.");
        }

        Directory.CreateDirectory(destinationDirectory);

        if (File.Exists(fullDestinationPath) && !overwrite)
        {
            throw new FileTransferFailureException("PolicyDenied", -32010, $"Destination file '{fullDestinationPath}' already exists.");
        }

        var stagingFileName = SanitizeIncomingStagingFileName(offer.FileName);
        var stagingDirectory = Path.Combine(Path.GetTempPath(), "rift-file-transfer", transferId);
        Directory.CreateDirectory(stagingDirectory);
        var stagingPath = Path.Combine(stagingDirectory, $"{stagingFileName}.part");
        if (File.Exists(stagingPath))
        {
            File.Delete(stagingPath);
        }

        var operationId = Guid.NewGuid().ToString("D");
        _operationService.CreateOperation(operationId, "file.receive", offer.SourceDeviceId, _identityManager.GetDeviceId());
        _operationService.TransitionOperation(operationId, OperationState.Pending, details: new Dictionary<string, object?>
        {
            ["transferId"] = transferId,
            ["fileName"] = offer.FileName,
            ["byteSize"] = offer.ByteSize
        });
        _operationService.TransitionOperation(operationId, OperationState.Dispatched);

        var transfer = new IncomingTransferState
        {
            TransferId = transferId,
            OperationId = operationId,
            SourceDeviceId = offer.SourceDeviceId,
            FileName = offer.FileName,
            MediaType = offer.MediaType,
            ByteSize = offer.ByteSize,
            ExpectedSha256 = offer.Sha256,
            ChunkSize = offer.ChunkSize,
            ExpectedChunkCount = offer.ChunkCount,
            DestinationPath = fullDestinationPath,
            StagingDirectory = stagingDirectory,
            StagingPath = stagingPath,
            Overwrite = overwrite
        };
        _incomingTransfers[transferId] = transfer;

        var envelope = new
        {
            rift = "0.1-draft",
            type = "file.accept",
            messageId = Guid.NewGuid().ToString("D"),
            sourceDeviceId = _identityManager.GetDeviceId(),
            payload = new
            {
                transferId,
                receivingDeviceId = _identityManager.GetDeviceId(),
                chunkSize = offer.ChunkSize
            }
        };

        await SendProtectedMessageAsync(offer.SourceDeviceId, EncodeEnvelope(envelope), cancellationToken).ConfigureAwait(false);
        await NotifyTransferProgressAsync(transfer, null, cancellationToken).ConfigureAwait(false);

        return new AcceptFileOfferResult
        {
            TransferId = transferId,
            OperationId = operationId,
            DestinationPath = fullDestinationPath
        };
    }

    public async Task<RejectFileOfferResult> RejectFileOfferAsync(
        string transferId,
        string failureReason,
        string? message,
        CancellationToken cancellationToken)
    {
        await PruneExpiredOffersAsync().ConfigureAwait(false);

        if (!_remoteOffers.TryRemove(transferId, out var offer))
        {
            throw new FileTransferFailureException("NotFound", -32009, $"Incoming file offer '{transferId}' was not found.");
        }

        var envelope = new
        {
            rift = "0.1-draft",
            type = "file.reject",
            messageId = Guid.NewGuid().ToString("D"),
            sourceDeviceId = _identityManager.GetDeviceId(),
            payload = new
            {
                transferId,
                failureReason,
                message
            }
        };

        await SendProtectedMessageAsync(offer.SourceDeviceId, EncodeEnvelope(envelope), cancellationToken).ConfigureAwait(false);
        LogEvent(SecurityEventTypes.PolicyDenied, offer.SourceDeviceId, SecurityEventSeverity.Info, SecurityEventOutcome.Denied, failureReason, null);

        return new RejectFileOfferResult
        {
            TransferId = transferId,
            Rejected = true
        };
    }

    public Task<ListFileTransfersResult> ListFileTransfersAsync()
    {
        var transfers = _outgoingTransfers.Values
            .Select(transfer => ToTransferInfo(transfer))
            .Concat(_incomingTransfers.Values.Select(transfer => ToTransferInfo(transfer)))
            .OrderByDescending(transfer => transfer.TransferId, StringComparer.Ordinal)
            .ToArray();

        return Task.FromResult(new ListFileTransfersResult
        {
            Transfers = transfers
        });
    }

    public async Task HandleOfferReceivedAsync(ReceivedFileOffer offer, CancellationToken cancellationToken)
    {
        EnsurePayloadIdentityMatches(offer.DeviceId, offer.PayloadSourceDeviceId, "file.offer");
        EnsurePeerCanUseFileTransfer(offer.DeviceId, offer.RequiredCapability);
        if (string.IsNullOrWhiteSpace(offer.TransferId) ||
            string.IsNullOrWhiteSpace(offer.FileName) ||
            offer.ByteSize < 0 ||
            string.IsNullOrWhiteSpace(offer.Sha256) ||
            offer.ChunkCount < 0 ||
            offer.ExpiresInMs <= 0 ||
            !string.Equals(offer.RequiredCapability, RequiredCapability, StringComparison.Ordinal))
        {
            throw new FileTransferFailureException("ProtocolError", -32001, "Malformed file.offer payload.");
        }

        if (offer.ByteSize > MaxIncomingOfferByteSize)
        {
            throw new FileTransferFailureException("PayloadTooLarge", -32007, "Incoming file offer exceeded the maximum supported size.");
        }

        _remoteOffers[offer.TransferId] = new RemoteFileOfferState
        {
            TransferId = offer.TransferId,
            SourceDeviceId = offer.DeviceId,
            FileName = offer.FileName,
            MediaType = offer.MediaType,
            ByteSize = offer.ByteSize,
            Sha256 = offer.Sha256,
            ChunkSize = NormalizeChunkSize(offer.ChunkSize),
            ChunkCount = offer.ChunkCount,
            ExpiresAt = _timeProvider.GetUtcNow().AddMilliseconds(offer.ExpiresInMs)
        };

        await NotifyFileOfferAsync(_remoteOffers[offer.TransferId], cancellationToken).ConfigureAwait(false);
    }

    public Task HandleAcceptReceivedAsync(string deviceId, string transferId, string receivingDeviceId, int? chunkSize, CancellationToken cancellationToken)
    {
        EnsurePayloadIdentityMatches(deviceId, receivingDeviceId, "file.accept");
        EnsurePeerCanUseFileTransfer(deviceId, RequiredCapability);

        if (!_outgoingTransfers.TryGetValue(transferId, out var transfer))
        {
            throw new FileTransferFailureException("NotFound", -32009, $"Outgoing transfer '{transferId}' was not found.");
        }

        EnsureOutgoingTransferPeerMatches(transfer, deviceId, "Accept");
        transfer.AcceptedChunkSize = chunkSize.HasValue ? NormalizeChunkSize(chunkSize.Value) : transfer.ChunkSize;
        transfer.SendTask ??= Task.Run(() => SendFileChunksAsync(transfer, cancellationToken), cancellationToken);
        return Task.CompletedTask;
    }

    public async Task HandleRejectReceivedAsync(string deviceId, string transferId, string failureReason, string? message, CancellationToken cancellationToken)
    {
        if (!_outgoingTransfers.TryGetValue(transferId, out var transfer))
        {
            return;
        }

        EnsureOutgoingTransferPeerMatches(transfer, deviceId, "Reject");
        var rejectedTransfer = _outgoingTransfers.TryRemove(transferId, out var removedTransfer) ? removedTransfer : transfer;
        TryTransitionFailure(rejectedTransfer.OperationId, failureReason);
        try
        {
            await NotifyTransferFailedAsync(
                rejectedTransfer.TransferId,
                rejectedTransfer.OperationId,
                rejectedTransfer.TargetDeviceId,
                rejectedTransfer.FileName,
                rejectedTransfer.ByteSize,
                failureReason,
                message,
                cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            rejectedTransfer.SendCancellation.Dispose();
        }
    }

    public async Task HandleChunkReceivedAsync(
        string deviceId,
        string transferId,
        int chunkIndex,
        long offset,
        int byteSize,
        string chunkSha256,
        string contentBase64,
        bool isLastChunk,
        CancellationToken cancellationToken)
    {
        if (!_incomingTransfers.TryGetValue(transferId, out var transfer))
        {
            throw new FileTransferFailureException("TransferStateMismatch", -32001, $"Incoming transfer '{transferId}' was not accepted.");
        }

        if (!string.Equals(transfer.SourceDeviceId, deviceId, StringComparison.Ordinal))
        {
            throw new FileTransferFailureException("Unauthorized", -32004, "Chunk sender did not match accepted file offer source.");
        }

        if (chunkIndex != transfer.NextChunkIndex)
        {
            throw new FileTransferFailureException("TransferStateMismatch", -32001, "Unexpected chunk index.");
        }

        if (offset != transfer.BytesTransferred)
        {
            throw new FileTransferFailureException("TransferStateMismatch", -32001, "Unexpected chunk offset.");
        }

        byte[] chunkBytes;
        try
        {
            chunkBytes = Convert.FromBase64String(contentBase64);
        }
        catch (FormatException)
        {
            throw new FileTransferFailureException("HashMismatch", -32006, "Chunk payload was not valid Base64.");
        }

        if (chunkBytes.Length != byteSize)
        {
            throw new FileTransferFailureException("HashMismatch", -32006, "Chunk byte size did not match the declared size.");
        }

        var computedChunkHash = Convert.ToHexStringLower(SHA256.HashData(chunkBytes));
        if (!string.Equals(computedChunkHash, chunkSha256, StringComparison.OrdinalIgnoreCase))
        {
            throw new FileTransferFailureException("HashMismatch", -32006, "Chunk SHA-256 verification failed.");
        }

        await using (var stream = new FileStream(transfer.StagingPath, FileMode.Append, FileAccess.Write, FileShare.None))
        {
            await stream.WriteAsync(chunkBytes, cancellationToken).ConfigureAwait(false);
        }

        transfer.BytesTransferred += byteSize;
        transfer.NextChunkIndex++;
        TransitionActiveIfPossible(transfer.OperationId);
        await NotifyTransferProgressAsync(transfer, null, cancellationToken).ConfigureAwait(false);
    }

    public async Task HandleCompleteReceivedAsync(
        string deviceId,
        string transferId,
        long byteSize,
        string sha256,
        int chunkCount,
        CancellationToken cancellationToken)
    {
        if (!_incomingTransfers.TryGetValue(transferId, out var transfer))
        {
            throw new FileTransferFailureException("TransferStateMismatch", -32001, $"Incoming transfer '{transferId}' was not accepted.");
        }

        if (!string.Equals(transfer.SourceDeviceId, deviceId, StringComparison.Ordinal))
        {
            throw new FileTransferFailureException("Unauthorized", -32004, "Completion sender did not match accepted file offer source.");
        }

        if (transfer.BytesTransferred != byteSize || transfer.ExpectedChunkCount != chunkCount)
        {
            throw new FileTransferFailureException("FileIntegrityFailed", -32006, "Transfer completion metadata did not match the received chunks.");
        }

        var finalHash = ComputeFileSha256(transfer.StagingPath);
        if (!string.Equals(finalHash, sha256, StringComparison.OrdinalIgnoreCase) ||
            !string.Equals(finalHash, transfer.ExpectedSha256, StringComparison.OrdinalIgnoreCase))
        {
            throw new FileTransferFailureException("FileIntegrityFailed", -32006, "Received file failed whole-file SHA-256 verification.");
        }

        if (File.Exists(transfer.DestinationPath))
        {
            if (!transfer.Overwrite)
            {
                throw new FileTransferFailureException("PolicyDenied", -32010, $"Destination file '{transfer.DestinationPath}' already exists.");
            }

            File.Delete(transfer.DestinationPath);
        }

        File.Move(transfer.StagingPath, transfer.DestinationPath);
        CleanupStagingDirectory(transfer.StagingDirectory);
        _remoteOffers.TryRemove(transferId, out _);
        _incomingTransfers.TryRemove(transferId, out _);

        _operationService.TransitionOperation(transfer.OperationId, OperationState.Done);
        await NotifyTransferCompletedAsync(
            transfer.TransferId,
            transfer.OperationId,
            transfer.SourceDeviceId,
            transfer.FileName,
            transfer.ByteSize,
            transfer.DestinationPath,
            cancellationToken).ConfigureAwait(false);
    }

    public async Task HandleCancelReceivedAsync(
        string deviceId,
        string transferId,
        string failureReason,
        string? message,
        CancellationToken cancellationToken)
    {
        if (_incomingTransfers.TryGetValue(transferId, out var incoming))
        {
            EnsureIncomingTransferPeerMatches(incoming, deviceId, "Cancel");
            var transferToCancel = _incomingTransfers.TryRemove(transferId, out var removedIncoming) ? removedIncoming : incoming;
            CleanupStagingDirectory(transferToCancel.StagingDirectory);
            TryTransitionFailure(transferToCancel.OperationId, failureReason);
            await NotifyTransferFailedAsync(
                transferToCancel.TransferId,
                transferToCancel.OperationId,
                transferToCancel.SourceDeviceId,
                transferToCancel.FileName,
                transferToCancel.ByteSize,
                failureReason,
                message,
                cancellationToken).ConfigureAwait(false);
        }

        if (_outgoingTransfers.TryGetValue(transferId, out var outgoing))
        {
            EnsureOutgoingTransferPeerMatches(outgoing, deviceId, "Cancel");
            var transferToCancel = _outgoingTransfers.TryRemove(transferId, out var removedOutgoing) ? removedOutgoing : outgoing;
            transferToCancel.SendCancellation.Cancel();
            TryTransitionFailure(transferToCancel.OperationId, failureReason);
            await NotifyTransferFailedAsync(
                transferToCancel.TransferId,
                transferToCancel.OperationId,
                transferToCancel.TargetDeviceId,
                transferToCancel.FileName,
                transferToCancel.ByteSize,
                failureReason,
                message,
                cancellationToken).ConfigureAwait(false);
            transferToCancel.SendCancellation.Dispose();
        }
    }

    private async Task SendFileChunksAsync(OutgoingTransferState transfer, CancellationToken cancellationToken)
    {
        using var linkedCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, transfer.SendCancellation.Token);
        var sendCancellationToken = linkedCts.Token;
        try
        {
            _operationService.TransitionOperation(transfer.OperationId, OperationState.Active);
            var chunkSize = transfer.AcceptedChunkSize ?? transfer.ChunkSize;
            await using var stream = new FileStream(transfer.LocalPath, FileMode.Open, FileAccess.Read, FileShare.Read);
            var buffer = new byte[chunkSize];
            var chunkIndex = 0;
            long offset = 0;

            while (true)
            {
                sendCancellationToken.ThrowIfCancellationRequested();
                var bytesRead = await stream.ReadAsync(buffer.AsMemory(0, chunkSize), sendCancellationToken).ConfigureAwait(false);
                if (bytesRead == 0)
                {
                    break;
                }

                var chunkBytes = buffer.AsSpan(0, bytesRead).ToArray();
                var envelope = new
                {
                    rift = "0.1-draft",
                    type = "file.chunk",
                    messageId = Guid.NewGuid().ToString("D"),
                    sourceDeviceId = _identityManager.GetDeviceId(),
                    payload = new
                    {
                        transferId = transfer.TransferId,
                        chunkIndex,
                        offset,
                        byteSize = bytesRead,
                        chunkSha256 = Convert.ToHexStringLower(SHA256.HashData(chunkBytes)),
                        contentBase64 = Convert.ToBase64String(chunkBytes),
                        isLastChunk = offset + bytesRead >= transfer.ByteSize
                    }
                };

                await SendProtectedMessageAsync(transfer.TargetDeviceId, EncodeEnvelope(envelope), sendCancellationToken).ConfigureAwait(false);

                offset += bytesRead;
                chunkIndex++;
                transfer.BytesTransferred = offset;
                await NotifyTransferProgressAsync(transfer, null, sendCancellationToken).ConfigureAwait(false);
            }

            var completeEnvelope = new
            {
                rift = "0.1-draft",
                type = "file.complete",
                messageId = Guid.NewGuid().ToString("D"),
                sourceDeviceId = _identityManager.GetDeviceId(),
                payload = new
                {
                    transferId = transfer.TransferId,
                    byteSize = transfer.ByteSize,
                    sha256 = transfer.Sha256,
                    chunkCount = transfer.ChunkCount
                }
            };

            await SendProtectedMessageAsync(transfer.TargetDeviceId, EncodeEnvelope(completeEnvelope), sendCancellationToken).ConfigureAwait(false);
            _operationService.TransitionOperation(transfer.OperationId, OperationState.Done);
            await NotifyTransferCompletedAsync(
                transfer.TransferId,
                transfer.OperationId,
                transfer.TargetDeviceId,
                transfer.FileName,
                transfer.ByteSize,
                null,
                sendCancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (transfer.SendCancellation.IsCancellationRequested && !cancellationToken.IsCancellationRequested)
        {
            _logger.LogInformation("File transfer {TransferId} stopped after remote cancellation.", transfer.TransferId);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or InvalidOperationException or FileTransferFailureException)
        {
            _logger.LogWarning(ex, "File transfer {TransferId} failed while sending.", transfer.TransferId);
            TryTransitionFailure(transfer.OperationId, "ConnectionLost");
            LogEvent(SecurityEventTypes.ConnectionLost, transfer.TargetDeviceId, SecurityEventSeverity.Error, SecurityEventOutcome.Failure, "ConnectionLost", transfer.OperationId);
            await NotifyTransferFailedAsync(
                transfer.TransferId,
                transfer.OperationId,
                transfer.TargetDeviceId,
                transfer.FileName,
                transfer.ByteSize,
                "ConnectionLost",
                ex.Message,
                cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            _outgoingTransfers.TryRemove(transfer.TransferId, out _);
            transfer.SendCancellation.Dispose();
        }
    }

    private async Task NotifyFileOfferAsync(RemoteFileOfferState offer, CancellationToken cancellationToken)
    {
        if (_ipcNotificationService is null)
        {
            return;
        }

        try
        {
            await _ipcNotificationService.NotifyAsync(
                "rift.onFileOffer",
                new
                {
                    transferId = offer.TransferId,
                    sourceDeviceId = offer.SourceDeviceId,
                    fileName = offer.FileName,
                    mediaType = offer.MediaType,
                    byteSize = offer.ByteSize,
                    sha256 = offer.Sha256,
                    chunkSize = offer.ChunkSize,
                    chunkCount = offer.ChunkCount,
                    expiresAt = offer.ExpiresAt.ToString("O")
                },
                cancellationToken).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Failed to notify IPC clients about file offer {TransferId}.", offer.TransferId);
        }
    }

    private async Task NotifyTransferProgressAsync(IncomingTransferState transfer, string? stateOverride, CancellationToken cancellationToken)
    {
        await NotifyTransferProgressCoreAsync(
            transfer.TransferId,
            transfer.OperationId,
            "incoming",
            transfer.SourceDeviceId,
            transfer.FileName,
            transfer.MediaType,
            transfer.ByteSize,
            transfer.BytesTransferred,
            stateOverride ?? "active",
            null,
            cancellationToken).ConfigureAwait(false);
    }

    private async Task NotifyTransferProgressAsync(OutgoingTransferState transfer, string? stateOverride, CancellationToken cancellationToken)
    {
        await NotifyTransferProgressCoreAsync(
            transfer.TransferId,
            transfer.OperationId,
            "outgoing",
            transfer.TargetDeviceId,
            transfer.FileName,
            transfer.MediaType,
            transfer.ByteSize,
            transfer.BytesTransferred,
            stateOverride ?? "active",
            null,
            cancellationToken).ConfigureAwait(false);
    }

    private async Task NotifyTransferProgressCoreAsync(
        string transferId,
        string operationId,
        string direction,
        string peerDeviceId,
        string fileName,
        string mediaType,
        long byteSize,
        long bytesTransferred,
        string state,
        string? failureReason,
        CancellationToken cancellationToken)
    {
        if (_ipcNotificationService is null)
        {
            return;
        }

        try
        {
            await _ipcNotificationService.NotifyAsync(
                "rift.onFileTransferProgress",
                new
                {
                    transferId,
                    operationId,
                    direction,
                    peerDeviceId,
                    fileName,
                    mediaType,
                    byteSize,
                    bytesTransferred,
                    state,
                    failureReason
                },
                cancellationToken).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Failed to send file transfer progress notification for {TransferId}.", transferId);
        }
    }

    private async Task NotifyTransferCompletedAsync(
        string transferId,
        string operationId,
        string peerDeviceId,
        string fileName,
        long byteSize,
        string? destinationPath,
        CancellationToken cancellationToken)
    {
        if (_ipcNotificationService is null)
        {
            return;
        }

        try
        {
            await _ipcNotificationService.NotifyAsync(
                "rift.onFileTransferCompleted",
                new
                {
                    transferId,
                    operationId,
                    peerDeviceId,
                    fileName,
                    byteSize,
                    destinationPath
                },
                cancellationToken).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Failed to notify completion for file transfer {TransferId}.", transferId);
        }
    }

    private async Task NotifyTransferFailedAsync(
        string transferId,
        string operationId,
        string peerDeviceId,
        string fileName,
        long byteSize,
        string failureReason,
        string? message,
        CancellationToken cancellationToken)
    {
        if (_ipcNotificationService is null)
        {
            return;
        }

        try
        {
            await _ipcNotificationService.NotifyAsync(
                "rift.onFileTransferFailed",
                new
                {
                    transferId,
                    operationId,
                    peerDeviceId,
                    fileName,
                    byteSize,
                    failureReason,
                    message
                },
                cancellationToken).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Failed to notify failure for file transfer {TransferId}.", transferId);
        }
    }

    private static byte[] EncodeEnvelope(object envelope)
    {
        return Encoding.UTF8.GetBytes(JsonSerializer.Serialize(envelope));
    }

    private static int ComputeChunkCount(long byteSize, int chunkSize)
    {
        if (byteSize == 0)
        {
            return 0;
        }

        return (int)((byteSize + chunkSize - 1) / chunkSize);
    }

    private static string SanitizeIncomingStagingFileName(string fileName)
    {
        var sanitized = Path.GetFileName(fileName).Trim();
        if (string.IsNullOrEmpty(sanitized) || sanitized.All(static ch => ch == '.'))
        {
            throw new FileTransferFailureException("ProtocolError", -32001, "Incoming file offer had an invalid file name.");
        }

        return sanitized;
    }

    private static int NormalizeChunkSize(int chunkSize)
    {
        if (chunkSize <= 0)
        {
            return DefaultChunkSize;
        }

        return Math.Min(chunkSize, MaxChunkSize);
    }

    private static string ComputeFileSha256(string path)
    {
        using var stream = File.OpenRead(path);
        return Convert.ToHexStringLower(SHA256.HashData(stream));
    }

    private void EnsurePeerCanUseFileTransfer(string deviceId, string requiredCapability)
    {
        var peer = _trustStore.GetPeer(deviceId);
        if (peer is null || peer.State != TrustState.Trusted)
        {
            throw new FileTransferFailureException("Unauthorized", -32004, "Peer is not trusted.");
        }

        if (!PeerHasCapability(deviceId, requiredCapability))
        {
            throw new FileTransferFailureException("CapabilityUnavailable", -32003, $"Capability '{requiredCapability}' is not negotiated for peer '{deviceId}'.");
        }
    }

    private bool PeerHasCapability(string deviceId, string requiredCapability)
    {
        var presence = _presenceService.GetPeerPresence(deviceId);
        return presence is not null && presence.Capabilities.Contains(requiredCapability, StringComparer.Ordinal);
    }

    private void EnsurePayloadIdentityMatches(string authenticatedDeviceId, string payloadDeviceId, string messageType)
    {
        if (string.Equals(authenticatedDeviceId, payloadDeviceId, StringComparison.Ordinal))
        {
            return;
        }

        LogEvent(SecurityEventTypes.AuthFailed, authenticatedDeviceId, SecurityEventSeverity.Critical, SecurityEventOutcome.Denied, "Unauthorized", null);
        throw new FileTransferFailureException("Unauthorized", -32004, $"{messageType} payload identity did not match the authenticated peer identity.");
    }

    private void EnsureOutgoingTransferPeerMatches(OutgoingTransferState transfer, string deviceId, string action)
    {
        if (string.Equals(transfer.TargetDeviceId, deviceId, StringComparison.Ordinal))
        {
            return;
        }

        LogEvent(SecurityEventTypes.AuthFailed, deviceId, SecurityEventSeverity.Critical, SecurityEventOutcome.Denied, "Unauthorized", transfer.OperationId);
        throw new FileTransferFailureException("Unauthorized", -32004, $"{action} sender did not match outgoing transfer target device.");
    }

    private void EnsureIncomingTransferPeerMatches(IncomingTransferState transfer, string deviceId, string action)
    {
        if (string.Equals(transfer.SourceDeviceId, deviceId, StringComparison.Ordinal))
        {
            return;
        }

        LogEvent(SecurityEventTypes.AuthFailed, deviceId, SecurityEventSeverity.Critical, SecurityEventOutcome.Denied, "Unauthorized", transfer.OperationId);
        throw new FileTransferFailureException("Unauthorized", -32004, $"{action} sender did not match incoming transfer source device.");
    }

    private Task PruneExpiredOffersAsync()
    {
        var now = _timeProvider.GetUtcNow();
        foreach (var entry in _remoteOffers)
        {
            if (entry.Value.ExpiresAt > now)
            {
                continue;
            }

            if (_remoteOffers.TryRemove(entry.Key, out var removed))
            {
                LogEvent(SecurityEventTypes.PolicyDenied, removed.SourceDeviceId, SecurityEventSeverity.Warning, SecurityEventOutcome.Failure, "OfferExpired", null);
            }
        }

        return Task.CompletedTask;
    }

    private async Task SendProtectedMessageAsync(string peerDeviceId, ReadOnlyMemory<byte> frameBody, CancellationToken cancellationToken)
    {
        try
        {
            await _transport.SendAsync(peerDeviceId, frameBody, cancellationToken).ConfigureAwait(false);
            return;
        }
        catch (InvalidOperationException ex) when (IsNoOpenSessionError(ex))
        {
            _logger.LogDebug(ex, "No active session for peer {PeerDeviceId}. Trying trusted reconnect for file transfer.", peerDeviceId);
        }

        await EnsureConnectedForTrustedPeerAsync(peerDeviceId, cancellationToken).ConfigureAwait(false);
        await _transport.SendAsync(peerDeviceId, frameBody, cancellationToken).ConfigureAwait(false);
    }

    private async Task EnsureConnectedForTrustedPeerAsync(string peerDeviceId, CancellationToken cancellationToken)
    {
        if (_transport.HasActiveSession(peerDeviceId))
        {
            return;
        }

        var peer = _trustStore.GetPeer(peerDeviceId);
        if (peer is null || peer.State != TrustState.Trusted)
        {
            throw new FileTransferFailureException("Unauthorized", -32004, $"Peer '{peerDeviceId}' is not trusted.");
        }

        if (peer.TrustedEndpoints.Count == 0)
        {
            await ReconnectTrustedPeerViaDiscoveryAsync(peerDeviceId, cancellationToken).ConfigureAwait(false);
            return;
        }

        var reconnectTask = _pendingTrustedReconnects.GetOrAdd(
            peerDeviceId,
            _ => ReconnectTrustedPeerCoreAsync(peerDeviceId, peer, cancellationToken));

        try
        {
            await reconnectTask.ConfigureAwait(false);
        }
        finally
        {
            if (reconnectTask.IsCompleted)
            {
                _pendingTrustedReconnects.TryRemove(peerDeviceId, out _);
            }
        }
    }

    private async Task ReconnectTrustedPeerCoreAsync(string peerDeviceId, PeerIdentity peer, CancellationToken cancellationToken)
    {
        Exception? lastError = null;
        foreach (var endpoint in peer.TrustedEndpoints)
        {
            try
            {
                using var timeoutCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
                timeoutCts.CancelAfter(TrustedReconnectTimeout);
                await _transport.ConnectToPeerAsync(endpoint.Address, endpoint.Port, timeoutCts.Token).ConfigureAwait(false);
                return;
            }
            catch (Exception ex) when (ex is not OperationCanceledException || !cancellationToken.IsCancellationRequested)
            {
                lastError = ex;
            }
        }

        if (_discoveryCoordinator.TryGetDiscoveredPeer(peerDeviceId, out var discoveredPeer) &&
            discoveredPeer is not null)
        {
            await ReconnectTrustedPeerViaDiscoveryAsync(peerDeviceId, cancellationToken).ConfigureAwait(false);
            return;
        }

        throw new FileTransferFailureException(
            "PeerUnreachable",
            -32000,
            $"Failed to reconnect trusted peer '{peerDeviceId}'. {lastError?.Message ?? "No endpoint succeeded."}");
    }

    private async Task ReconnectTrustedPeerViaDiscoveryAsync(string peerDeviceId, CancellationToken cancellationToken)
    {
        if (!_discoveryCoordinator.TryGetDiscoveredPeer(peerDeviceId, out var peer) || peer is null)
        {
            throw new FileTransferFailureException("PeerUnreachable", -32000, $"Trusted peer '{peerDeviceId}' is not currently discoverable.");
        }

        var endpoints = peer.ObservedEndpoints.Count > 0
            ? peer.ObservedEndpoints
            : [new DiscoveredPeerEndpoint { Address = peer.Address, Port = peer.Port }];

        Exception? lastError = null;
        foreach (var endpoint in endpoints)
        {
            try
            {
                using var timeoutCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
                timeoutCts.CancelAfter(TrustedReconnectTimeout);
                await _transport.ConnectToPeerAsync(endpoint.Address, endpoint.Port, timeoutCts.Token).ConfigureAwait(false);
                return;
            }
            catch (Exception ex) when (ex is not OperationCanceledException || !cancellationToken.IsCancellationRequested)
            {
                lastError = ex;
            }
        }

        throw new FileTransferFailureException(
            "PeerUnreachable",
            -32000,
            $"Failed to reconnect trusted peer '{peerDeviceId}' using discovery endpoints. {lastError?.Message ?? "No endpoint succeeded."}");
    }

    private static bool IsNoOpenSessionError(InvalidOperationException ex)
    {
        return ex.Message.Contains("No open session exists", StringComparison.Ordinal);
    }

    private void TransitionActiveIfPossible(string operationId)
    {
        try
        {
            _operationService.TransitionOperation(operationId, OperationState.Active);
        }
        catch (OperationTransitionException)
        {
        }
    }

    private void TryTransitionFailure(string operationId, string failureReason)
    {
        try
        {
            _operationService.TransitionOperation(operationId, OperationState.Failed, failureReason);
        }
        catch (OperationTransitionException)
        {
        }
    }

    private void CleanupStagingDirectory(string stagingDirectory)
    {
        try
        {
            if (Directory.Exists(stagingDirectory))
            {
                Directory.Delete(stagingDirectory, recursive: true);
            }
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Failed to clean up staging directory {StagingDirectory}.", stagingDirectory);
        }
    }

    private void LogEvent(string eventType, string? peerDeviceId, SecurityEventSeverity severity, SecurityEventOutcome outcome, string? failureReason, string? operationId)
    {
        _ = _securityEventLog.LogEventAsync(new SecurityEventRecord
        {
            EventType = eventType,
            Severity = severity,
            LocalDeviceId = _identityManager.GetDeviceId(),
            PeerDeviceId = peerDeviceId,
            OperationId = operationId,
            Outcome = outcome,
            FailureReason = failureReason
        }).ContinueWith(
            task =>
            {
                if (task.IsFaulted)
                {
                    _logger.LogError(task.Exception, "Failed to persist file transfer event {EventType}.", eventType);
                }
            },
            CancellationToken.None,
            TaskContinuationOptions.ExecuteSynchronously,
            TaskScheduler.Default);
    }

    private FileTransferInfo ToTransferInfo(OutgoingTransferState transfer)
    {
        var operation = TryGetOperation(transfer.OperationId);
        return new FileTransferInfo
        {
            TransferId = transfer.TransferId,
            OperationId = transfer.OperationId,
            Direction = "outgoing",
            PeerDeviceId = transfer.TargetDeviceId,
            FileName = transfer.FileName,
            MediaType = transfer.MediaType,
            ByteSize = transfer.ByteSize,
            BytesTransferred = transfer.BytesTransferred,
            State = operation?.State ?? "Unknown",
            FailureReason = operation?.FailureReason,
            DestinationPath = null
        };
    }

    private FileTransferInfo ToTransferInfo(IncomingTransferState transfer)
    {
        var operation = TryGetOperation(transfer.OperationId);
        return new FileTransferInfo
        {
            TransferId = transfer.TransferId,
            OperationId = transfer.OperationId,
            Direction = "incoming",
            PeerDeviceId = transfer.SourceDeviceId,
            FileName = transfer.FileName,
            MediaType = transfer.MediaType,
            ByteSize = transfer.ByteSize,
            BytesTransferred = transfer.BytesTransferred,
            State = operation?.State ?? "Unknown",
            FailureReason = operation?.FailureReason,
            DestinationPath = transfer.DestinationPath
        };
    }

    private OperationRecord? TryGetOperation(string operationId)
    {
        try
        {
            return _operationService.GetOperation(operationId);
        }
        catch (InvalidOperationException)
        {
            return null;
        }
    }

    private sealed class RemoteFileOfferState
    {
        public string TransferId { get; init; } = string.Empty;
        public string SourceDeviceId { get; init; } = string.Empty;
        public string FileName { get; init; } = string.Empty;
        public string MediaType { get; init; } = string.Empty;
        public long ByteSize { get; init; }
        public string Sha256 { get; init; } = string.Empty;
        public int ChunkSize { get; init; }
        public int ChunkCount { get; init; }
        public DateTimeOffset ExpiresAt { get; init; }
    }

    private sealed class OutgoingTransferState
    {
        public string TransferId { get; init; } = string.Empty;
        public string OperationId { get; init; } = string.Empty;
        public string TargetDeviceId { get; init; } = string.Empty;
        public string LocalPath { get; init; } = string.Empty;
        public string FileName { get; init; } = string.Empty;
        public string MediaType { get; init; } = string.Empty;
        public long ByteSize { get; init; }
        public long BytesTransferred { get; set; }
        public string Sha256 { get; init; } = string.Empty;
        public int ChunkSize { get; init; }
        public int ChunkCount { get; init; }
        public int? AcceptedChunkSize { get; set; }
        public DateTimeOffset ExpiresAt { get; init; }
        public CancellationTokenSource SendCancellation { get; init; } = new();
        public Task? SendTask { get; set; }
    }

    private sealed class IncomingTransferState
    {
        public string TransferId { get; init; } = string.Empty;
        public string OperationId { get; init; } = string.Empty;
        public string SourceDeviceId { get; init; } = string.Empty;
        public string FileName { get; init; } = string.Empty;
        public string MediaType { get; init; } = string.Empty;
        public long ByteSize { get; init; }
        public long BytesTransferred { get; set; }
        public string ExpectedSha256 { get; init; } = string.Empty;
        public int ChunkSize { get; init; }
        public int ExpectedChunkCount { get; init; }
        public int NextChunkIndex { get; set; }
        public string DestinationPath { get; init; } = string.Empty;
        public string StagingDirectory { get; init; } = string.Empty;
        public string StagingPath { get; init; } = string.Empty;
        public bool Overwrite { get; init; }
    }
}
