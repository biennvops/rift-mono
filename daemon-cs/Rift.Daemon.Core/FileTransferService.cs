using System.Collections.Concurrent;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;
using Rift.Daemon.Core.Data;
using Rift.Daemon.Core.Interfaces;

namespace Rift.Daemon.Core;

public sealed class FileTransferService : IFileTransferService
{
    private const string RequiredCapability = "file.transfer";
    private const int DefaultChunkSize = 256 * 1024;
    private const int MaxChunkSize = 4 * 1024 * 1024;
    private const int DefaultOfferExpiryMs = 300000;
    private static readonly TimeSpan TrustedReconnectTimeout = TimeSpan.FromSeconds(3);
    private static readonly TimeSpan DuplicateReconnectRetryDelay = TimeSpan.FromSeconds(1);
    private static readonly TimeSpan CommitAcknowledgementTimeout = TimeSpan.FromMinutes(5);
    private const int DuplicateReconnectRetryAttempts = 3;

    private readonly ITransport _transport;
    private readonly ITrustStore _trustStore;
    private readonly IDiscoveryCoordinator _discoveryCoordinator;
    private readonly IPresenceService _presenceService;
    private readonly IIdentityManager _identityManager;
    private readonly ISecurityEventLog _securityEventLog;
    private readonly IOperationService _operationService;
    private readonly IIpcNotificationService? _ipcNotificationService;
    private readonly ILogger<FileTransferService> _logger;
    private readonly string _incomingStagingRoot;
    private readonly TimeProvider _timeProvider = TimeProvider.System;

    private readonly ConcurrentDictionary<string, RemoteFileOfferState> _remoteOffers = new(StringComparer.Ordinal);
    private readonly ConcurrentDictionary<string, OutgoingTransferState> _outgoingTransfers = new(StringComparer.Ordinal);
    private readonly ConcurrentDictionary<string, OutgoingTransferState> _pausedOutgoingTransfers = new(StringComparer.Ordinal);
    private readonly ConcurrentDictionary<string, IncomingTransferState> _incomingTransfers = new(StringComparer.Ordinal);
    private readonly ConcurrentDictionary<string, Task> _pendingTrustedReconnects = new(StringComparer.Ordinal);
    private readonly ConcurrentDictionary<string, int> _peerFileTransferVersions = new(StringComparer.Ordinal);

    public event EventHandler<FileTransferLifecycleEventArgs>? TransferUpdated;

    public FileTransferService(
        ITransport transport,
        ITrustStore trustStore,
        IDiscoveryCoordinator discoveryCoordinator,
        IPresenceService presenceService,
        IIdentityManager identityManager,
        ISecurityEventLog securityEventLog,
        IOperationService operationService,
        IIpcNotificationService? ipcNotificationService = null,
        ILogger<FileTransferService>? logger = null,
        DatabaseContext? databaseContext = null)
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
        _incomingStagingRoot = databaseContext is null
            ? Path.Combine(Path.GetTempPath(), "rift-file-transfer", Guid.NewGuid().ToString("N"))
            : Path.Combine(Path.GetDirectoryName(databaseContext.DatabasePath)!, "incoming");
        ResetIncomingStagingRoot();
        _transport.SessionStateChanged += OnSessionStateChanged;
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

        if (File.Exists(fullDestinationPath) && !overwrite)
        {
            throw new FileTransferFailureException("PolicyDenied", -32010, $"Destination file '{fullDestinationPath}' already exists.");
        }

        SanitizeIncomingStagingFileName(offer.FileName);
        var stagingDirectory = Path.Combine(_incomingStagingRoot, transferId);
        CreatePrivateDirectory(stagingDirectory);
        var stagingPath = Path.Combine(stagingDirectory, "content.part");
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
            ExpectedChunkCount = ComputeChunkCount(offer.ByteSize, offer.ChunkSize),
            DestinationPath = fullDestinationPath,
            StagingDirectory = stagingDirectory,
            StagingPath = stagingPath,
            Overwrite = overwrite,
            NegotiatedVersion = offer.NegotiatedVersion
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

        try
        {
            await SendProtectedMessageAsync(offer.SourceDeviceId, EncodeEnvelope(envelope), cancellationToken).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            _logger.LogDebug(ex, "Best-effort file.reject failed for {TransferId}.", transferId);
        }
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
            .Concat(_pausedOutgoingTransfers.Values)
            .GroupBy(transfer => transfer.TransferId, StringComparer.Ordinal)
            .Select(group => group.First())
            .Select(transfer => ToTransferInfo(transfer))
            .Concat(_incomingTransfers.Values.Select(transfer => ToTransferInfo(transfer)))
            .OrderByDescending(transfer => transfer.TransferId, StringComparer.Ordinal)
            .ToArray();

        return Task.FromResult(new ListFileTransfersResult
        {
            Transfers = transfers
        });
    }

    public Task<ListPendingFileCommitsResult> ListPendingFileCommitsAsync()
    {
        var commits = _incomingTransfers.Values
            .Where(transfer => transfer.IsReadyToCommit)
            .OrderBy(transfer => transfer.TransferId, StringComparer.Ordinal)
            .Select(ToPendingFileCommitInfo)
            .ToArray();

        return Task.FromResult(new ListPendingFileCommitsResult
        {
            Commits = commits
        });
    }

    public async Task<ConfirmFileCommitResult> ConfirmFileCommitAsync(
        string transferId,
        string destinationPath,
        CancellationToken cancellationToken)
    {
        if (!_incomingTransfers.TryGetValue(transferId, out var transfer) || !transfer.IsReadyToCommit)
        {
            throw new FileTransferFailureException("NotFound", -32009, $"Pending file commit '{transferId}' was not found.");
        }
        if (string.IsNullOrWhiteSpace(destinationPath))
        {
            throw new FileTransferFailureException("PolicyDenied", -32010, "A committed destination path is required.");
        }

        await transfer.CommitGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (!_incomingTransfers.ContainsKey(transferId) || !transfer.IsReadyToCommit)
            {
                throw new FileTransferFailureException("NotFound", -32009, $"Pending file commit '{transferId}' was not found.");
            }

            var fullDestinationPath = Path.GetFullPath(destinationPath);
            if (!File.Exists(fullDestinationPath))
            {
                throw new FileTransferFailureException("NotFound", -32009, $"Committed file '{fullDestinationPath}' was not found.");
            }

            var fileInfo = new FileInfo(fullDestinationPath);
            if (fileInfo.Length != transfer.ByteSize ||
                !string.Equals(ComputeFileSha256(fullDestinationPath), transfer.ExpectedSha256, StringComparison.OrdinalIgnoreCase))
            {
                throw new FileTransferFailureException("HashMismatch", -32006, "Committed file did not match the verified incoming transfer.");
            }

            transfer.IsLocallyCommitted = true;
            transfer.CommittedDestinationPath = fullDestinationPath;
            if (transfer.NegotiatedVersion >= 2)
            {
                await SendCommittedAsync(transfer, cancellationToken).ConfigureAwait(false);
            }

            await FinalizeIncomingCommitAsync(transfer, fullDestinationPath, cancellationToken).ConfigureAwait(false);

            return new ConfirmFileCommitResult
            {
                TransferId = transferId,
                Committed = true,
                DestinationPath = fullDestinationPath
            };
        }
        finally
        {
            transfer.CommitGate.Release();
        }
    }

    public async Task<FailFileCommitResult> FailFileCommitAsync(
        string transferId,
        string failureReason,
        string? message,
        CancellationToken cancellationToken)
    {
        if (!_incomingTransfers.TryGetValue(transferId, out var transfer) || !transfer.IsReadyToCommit)
        {
            throw new FileTransferFailureException("NotFound", -32009, $"Pending file commit '{transferId}' was not found.");
        }

        await transfer.CommitGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (!_incomingTransfers.TryRemove(transferId, out _))
            {
                throw new FileTransferFailureException("NotFound", -32009, $"Pending file commit '{transferId}' was not found.");
            }

            CleanupStagingDirectory(transfer.StagingDirectory);
            TryTransitionFailure(transfer.OperationId, failureReason);
            await TrySendCancelAsync(
                transfer.SourceDeviceId,
                transfer.TransferId,
                failureReason,
                message ?? "Local file publication failed.",
                cancellationToken).ConfigureAwait(false);
            await NotifyTransferFailedAsync(
                transfer.TransferId,
                transfer.OperationId,
                "incoming",
                transfer.SourceDeviceId,
                transfer.FileName,
                transfer.ByteSize,
                failureReason,
                message,
                cancellationToken).ConfigureAwait(false);

            return new FailFileCommitResult
            {
                TransferId = transferId,
                Failed = true
            };
        }
        finally
        {
            transfer.CommitGate.Release();
        }
    }

    public async Task<FileTransferInfo> CancelTransferAsync(
        string transferId,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (string.IsNullOrWhiteSpace(transferId))
        {
            throw new FileTransferFailureException("NotFound", -32009, "transferId is required.");
        }

        const string failureReason = "Cancelled";
        const string message = "Transfer cancelled by local user.";

        if (_outgoingTransfers.TryGetValue(transferId, out var outgoing) ||
            _pausedOutgoingTransfers.TryGetValue(transferId, out outgoing))
        {
            outgoing!.SendCancellation.Cancel();
            _outgoingTransfers.TryRemove(transferId, out _);
            _pausedOutgoingTransfers.TryRemove(transferId, out _);
            await TrySendCancelAsync(outgoing.TargetDeviceId, transferId, failureReason, message, cancellationToken).ConfigureAwait(false);
            TryTransitionFailure(outgoing.OperationId, failureReason);
            await NotifyTransferFailedAsync(
                outgoing.TransferId,
                outgoing.OperationId,
                "outgoing",
                outgoing.TargetDeviceId,
                outgoing.FileName,
                outgoing.ByteSize,
                failureReason,
                message,
                cancellationToken).ConfigureAwait(false);
            return ToTransferInfo(outgoing);
        }

        if (_incomingTransfers.TryGetValue(transferId, out var incoming))
        {
            await TrySendCancelAsync(incoming.SourceDeviceId, transferId, failureReason, message, cancellationToken).ConfigureAwait(false);
            _incomingTransfers.TryRemove(transferId, out _);
            CleanupStagingDirectory(incoming.StagingDirectory);
            TryTransitionFailure(incoming.OperationId, failureReason);
            await NotifyTransferFailedAsync(
                incoming.TransferId,
                incoming.OperationId,
                "incoming",
                incoming.SourceDeviceId,
                incoming.FileName,
                incoming.ByteSize,
                failureReason,
                message,
                cancellationToken).ConfigureAwait(false);
            return ToTransferInfo(incoming);
        }

        throw new FileTransferFailureException("NotFound", -32009, $"Transfer '{transferId}' was not found.");
    }

    public async Task HandleOfferReceivedAsync(ReceivedFileOffer offer, CancellationToken cancellationToken)
    {
        EnsurePayloadIdentityMatches(offer.DeviceId, offer.PayloadSourceDeviceId, "file.offer");
        EnsurePeerCanUseFileTransfer(offer.DeviceId, offer.RequiredCapability);
        if (string.IsNullOrWhiteSpace(offer.TransferId) ||
            string.IsNullOrWhiteSpace(offer.FileName) ||
            offer.ByteSize < 0 ||
            string.IsNullOrWhiteSpace(offer.Sha256) ||
            offer.ChunkCount <= 0 ||
            offer.ExpiresInMs <= 0 ||
            !string.Equals(offer.RequiredCapability, RequiredCapability, StringComparison.Ordinal))
        {
            throw new FileTransferFailureException("ProtocolError", -32001, "Malformed file.offer payload.");
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
            ExpiresAt = _timeProvider.GetUtcNow().AddMilliseconds(offer.ExpiresInMs),
            NegotiatedVersion = GetPeerFileTransferVersion(offer.DeviceId)
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
        transfer.AcceptedChunkCount = ComputeChunkCount(transfer.ByteSize, transfer.AcceptedChunkSize.Value);
        transfer.RequiresCommitAcknowledgement = PeerSupportsFileTransferVersion(deviceId, 2);
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
        _pausedOutgoingTransfers.TryRemove(transferId, out _);
        var rejectedTransfer = _outgoingTransfers.TryRemove(transferId, out var removedTransfer) ? removedTransfer : transfer;
        TryTransitionFailure(rejectedTransfer.OperationId, failureReason);
        LogEvent(SecurityEventTypes.FileTransferRejected, deviceId, SecurityEventSeverity.Warning, SecurityEventOutcome.Denied, failureReason, rejectedTransfer.OperationId);
        try
        {
            await NotifyTransferFailedAsync(
                rejectedTransfer.TransferId,
                rejectedTransfer.OperationId,
                "outgoing",
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

        if (transfer.BytesTransferred != byteSize ||
            transfer.ExpectedChunkCount != chunkCount ||
            transfer.NextChunkIndex != chunkCount)
        {
            throw new FileTransferFailureException("FileIntegrityFailed", -32006, "Transfer completion metadata did not match the received chunks.");
        }

        var finalHash = ComputeFileSha256(transfer.StagingPath);
        if (!string.Equals(finalHash, sha256, StringComparison.OrdinalIgnoreCase) ||
            !string.Equals(finalHash, transfer.ExpectedSha256, StringComparison.OrdinalIgnoreCase))
        {
            throw new FileTransferFailureException("FileIntegrityFailed", -32006, "Received file failed whole-file SHA-256 verification.");
        }

        transfer.IsReadyToCommit = true;
        _remoteOffers.TryRemove(transferId, out _);
        await NotifyTransferReadyToCommitAsync(transfer, cancellationToken).ConfigureAwait(false);
    }

    public async Task HandleCommittedReceivedAsync(
        string deviceId,
        string transferId,
        long byteSize,
        string sha256,
        CancellationToken cancellationToken)
    {
        if (!_outgoingTransfers.TryGetValue(transferId, out var transfer) &&
            !_pausedOutgoingTransfers.TryGetValue(transferId, out transfer))
        {
            return;
        }
        EnsureOutgoingTransferPeerMatches(transfer!, deviceId, "Commit");
        if (byteSize != transfer!.ByteSize ||
            !string.Equals(sha256, transfer.Sha256, StringComparison.OrdinalIgnoreCase))
        {
            throw new FileTransferFailureException("HashMismatch", -32006, "Committed file metadata did not match the outgoing transfer.");
        }

        transfer.CommitAcknowledgement.TrySetResult();
        await Task.CompletedTask;
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
                "incoming",
                transferToCancel.SourceDeviceId,
                transferToCancel.FileName,
                transferToCancel.ByteSize,
                failureReason,
                message,
                cancellationToken).ConfigureAwait(false);
        }

        if (_outgoingTransfers.TryGetValue(transferId, out var outgoing) ||
            _pausedOutgoingTransfers.TryGetValue(transferId, out outgoing))
        {
            EnsureOutgoingTransferPeerMatches(outgoing!, deviceId, "Cancel");
            _pausedOutgoingTransfers.TryRemove(transferId, out _);
            var transferToCancel = _outgoingTransfers.TryRemove(transferId, out var removedOutgoing) ? removedOutgoing : outgoing!;
            transferToCancel.SendCancellation.Cancel();
            TryTransitionFailure(transferToCancel.OperationId, failureReason);
            await NotifyTransferFailedAsync(
                transferToCancel.TransferId,
                transferToCancel.OperationId,
                "outgoing",
                transferToCancel.TargetDeviceId,
                transferToCancel.FileName,
                transferToCancel.ByteSize,
                failureReason,
                message,
                cancellationToken).ConfigureAwait(false);
            transferToCancel.SendCancellation.Dispose();
        }
    }

    public async Task HandleResumeReceivedAsync(
        string deviceId,
        string transferId,
        string receivingDeviceId,
        int nextChunkIndex,
        long offset,
        CancellationToken cancellationToken)
    {
        EnsurePayloadIdentityMatches(deviceId, receivingDeviceId, "file.resume");
        EnsurePeerCanUseFileTransfer(deviceId, RequiredCapability);

        if (!_pausedOutgoingTransfers.TryGetValue(transferId, out var transfer))
        {
            if (_outgoingTransfers.TryGetValue(transferId, out var activeTransfer))
            {
                EnsureOutgoingTransferPeerMatches(activeTransfer, deviceId, "Resume");
                if (!activeTransfer.RequiresCommitAcknowledgement || offset != activeTransfer.ByteSize)
                {
                    throw new FileTransferFailureException("ProtocolError", -32001, $"Outgoing transfer '{transferId}' is not paused.");
                }

                ValidateResumePosition(activeTransfer, nextChunkIndex, offset);
                await SendCompleteAsync(activeTransfer, cancellationToken).ConfigureAwait(false);
                return;
            }

            throw new FileTransferFailureException("NotFound", -32009, $"Outgoing transfer '{transferId}' was not found.");
        }

        EnsureOutgoingTransferPeerMatches(transfer, deviceId, "Resume");
        ValidateResumePosition(transfer, nextChunkIndex, offset);

        transfer.BytesTransferred = offset;
        transfer.NextChunkIndex = nextChunkIndex;
        if (!_pausedOutgoingTransfers.TryRemove(transferId, out transfer))
        {
            throw new FileTransferFailureException("NotFound", -32009, $"Outgoing transfer '{transferId}' was no longer paused.");
        }

        _outgoingTransfers[transferId] = transfer;
        transfer.SendTask = Task.Run(() => SendFileChunksAsync(transfer, cancellationToken), cancellationToken);
    }

    private async Task SendFileChunksAsync(OutgoingTransferState transfer, CancellationToken cancellationToken)
    {
        using var linkedCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, transfer.SendCancellation.Token);
        var sendCancellationToken = linkedCts.Token;
        var retainOutgoingState = false;
        var sendingProtectedMessage = false;
        try
        {
            TransitionActiveIfPossible(transfer.OperationId);
            var chunkSize = transfer.AcceptedChunkSize ?? transfer.ChunkSize;
            await using var stream = new FileStream(transfer.LocalPath, FileMode.Open, FileAccess.Read, FileShare.Read);
            var buffer = new byte[chunkSize];
            var chunkIndex = transfer.NextChunkIndex;
            long offset = transfer.BytesTransferred;
            if (offset > 0)
            {
                stream.Seek(offset, SeekOrigin.Begin);
            }

            var sendEmptyChunk = transfer.ByteSize == 0 && chunkIndex == 0;
            while (true)
            {
                sendCancellationToken.ThrowIfCancellationRequested();
                int bytesRead;
                if (sendEmptyChunk)
                {
                    bytesRead = 0;
                    sendEmptyChunk = false;
                }
                else
                {
                    bytesRead = await stream.ReadAsync(buffer.AsMemory(0, chunkSize), sendCancellationToken).ConfigureAwait(false);
                    if (bytesRead == 0)
                    {
                        break;
                    }
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

                sendingProtectedMessage = true;
                await SendProtectedMessageAsync(transfer.TargetDeviceId, EncodeEnvelope(envelope), sendCancellationToken).ConfigureAwait(false);
                sendingProtectedMessage = false;

                offset += bytesRead;
                chunkIndex++;
                transfer.BytesTransferred = offset;
                transfer.NextChunkIndex = chunkIndex;
                await NotifyTransferProgressAsync(transfer, null, sendCancellationToken).ConfigureAwait(false);
            }

            sendingProtectedMessage = true;
            await SendCompleteAsync(transfer, sendCancellationToken).ConfigureAwait(false);
            sendingProtectedMessage = false;
            if (transfer.RequiresCommitAcknowledgement)
            {
                await transfer.CommitAcknowledgement.Task
                    .WaitAsync(CommitAcknowledgementTimeout, sendCancellationToken)
                    .ConfigureAwait(false);
            }
            _operationService.TransitionOperation(transfer.OperationId, OperationState.Done);
            await NotifyTransferCompletedAsync(
                transfer.TransferId,
                transfer.OperationId,
                "outgoing",
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
        catch (Exception ex) when (IsRecoverableTransferInterruption(ex, sendingProtectedMessage))
        {
            _logger.LogWarning(ex, "File transfer {TransferId} was interrupted while sending.", transfer.TransferId);
            retainOutgoingState = true;
            transfer.SendTask = null;
            _outgoingTransfers.TryRemove(transfer.TransferId, out _);
            _pausedOutgoingTransfers[transfer.TransferId] = transfer;
            LogEvent(SecurityEventTypes.ConnectionLost, transfer.TargetDeviceId, SecurityEventSeverity.Error, SecurityEventOutcome.Failure, "ConnectionLost", transfer.OperationId);
            await NotifyTransferFailedAsync(
                transfer.TransferId,
                transfer.OperationId,
                "outgoing",
                transfer.TargetDeviceId,
                transfer.FileName,
                transfer.ByteSize,
                "ConnectionLost",
                ex.Message,
                cancellationToken).ConfigureAwait(false);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or InvalidOperationException or FileTransferFailureException or TimeoutException)
        {
            var failureReason = GetTerminalSendFailureReason(ex);
            _logger.LogWarning(ex, "File transfer {TransferId} failed terminally while sending.", transfer.TransferId);
            TryTransitionFailure(transfer.OperationId, failureReason);
            await NotifyTransferFailedAsync(
                transfer.TransferId,
                transfer.OperationId,
                "outgoing",
                transfer.TargetDeviceId,
                transfer.FileName,
                transfer.ByteSize,
                failureReason,
                ex.Message,
                cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            if (!retainOutgoingState)
            {
                transfer.SendTask = null;
                _outgoingTransfers.TryRemove(transfer.TransferId, out _);
                _pausedOutgoingTransfers.TryRemove(transfer.TransferId, out _);
                transfer.SendCancellation.Dispose();
            }
        }
    }

    private void OnSessionStateChanged(object? sender, SessionStateChangedEventArgs args)
    {
        if (!args.IsOnline)
        {
            _peerFileTransferVersions.TryRemove(args.PeerDeviceId, out _);
            return;
        }
        if (!args.AllowsProtectedTraffic)
        {
            return;
        }

        _peerFileTransferVersions[args.PeerDeviceId] =
            args.SelectedCapabilityVersions.TryGetValue("file.transfer", out var fileTransferVersion)
                ? fileTransferVersion
                : 1;
        var resumableTransfers = _incomingTransfers.Values
            .Where(transfer => string.Equals(transfer.SourceDeviceId, args.PeerDeviceId, StringComparison.Ordinal))
            .ToArray();
        if (resumableTransfers.Length == 0)
        {
            return;
        }

        _ = Task.Run(async () =>
        {
            foreach (var transfer in resumableTransfers)
            {
                try
                {
                    if (transfer.IsReadyToCommit)
                    {
                        if (transfer.IsLocallyCommitted)
                        {
                            await transfer.CommitGate.WaitAsync(CancellationToken.None).ConfigureAwait(false);
                            try
                            {
                                if (_incomingTransfers.TryGetValue(transfer.TransferId, out var currentTransfer) &&
                                    ReferenceEquals(currentTransfer, transfer) &&
                                    transfer.IsReadyToCommit &&
                                    transfer.IsLocallyCommitted)
                                {
                                    await SendCommittedAsync(transfer, CancellationToken.None).ConfigureAwait(false);
                                    await FinalizeIncomingCommitAsync(
                                        transfer,
                                        transfer.CommittedDestinationPath ?? transfer.DestinationPath,
                                        CancellationToken.None).ConfigureAwait(false);
                                }
                            }
                            finally
                            {
                                transfer.CommitGate.Release();
                            }
                        }
                        continue;
                    }

                    var envelope = new
                    {
                        rift = "0.1-draft",
                        type = "file.resume",
                        messageId = Guid.NewGuid().ToString("D"),
                        sourceDeviceId = _identityManager.GetDeviceId(),
                        payload = new
                        {
                            transferId = transfer.TransferId,
                            receivingDeviceId = _identityManager.GetDeviceId(),
                            nextChunkIndex = transfer.NextChunkIndex,
                            offset = transfer.BytesTransferred
                        }
                    };

                    await SendProtectedMessageAsync(args.PeerDeviceId, EncodeEnvelope(envelope), CancellationToken.None).ConfigureAwait(false);
                }
                catch (Exception ex)
                {
                    _logger.LogDebug(ex, "Failed to send file.resume for {TransferId}.", transfer.TransferId);
                }
            }
        });
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

    private async Task NotifyTransferReadyToCommitAsync(
        IncomingTransferState transfer,
        CancellationToken cancellationToken)
    {
        RaiseTransferUpdated(new FileTransferLifecycleEventArgs
        {
            TransferId = transfer.TransferId,
            OperationId = transfer.OperationId,
            Direction = "incoming",
            PeerDeviceId = transfer.SourceDeviceId,
            FileName = transfer.FileName,
            ByteSize = transfer.ByteSize,
            BytesTransferred = transfer.ByteSize,
            State = "ready_to_commit",
            DestinationPath = transfer.DestinationPath
        });

        if (_ipcNotificationService is null)
        {
            return;
        }

        try
        {
            await _ipcNotificationService.NotifyAsync(
                "rift.onFileTransferReadyToCommit",
                ToPendingFileCommitInfo(transfer),
                cancellationToken).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Failed to notify pending commit for file transfer {TransferId}.", transfer.TransferId);
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
        RaiseTransferUpdated(new FileTransferLifecycleEventArgs
        {
            TransferId = transferId,
            OperationId = operationId,
            Direction = direction,
            PeerDeviceId = peerDeviceId,
            FileName = fileName,
            ByteSize = byteSize,
            BytesTransferred = bytesTransferred,
            State = state,
            FailureReason = failureReason
        });

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
        string direction,
        string peerDeviceId,
        string fileName,
        long byteSize,
        string? destinationPath,
        CancellationToken cancellationToken)
    {
        RaiseTransferUpdated(new FileTransferLifecycleEventArgs
        {
            TransferId = transferId,
            OperationId = operationId,
            Direction = direction,
            PeerDeviceId = peerDeviceId,
            FileName = fileName,
            ByteSize = byteSize,
            BytesTransferred = byteSize,
            State = "done",
            DestinationPath = destinationPath
        });

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
        string direction,
        string peerDeviceId,
        string fileName,
        long byteSize,
        string failureReason,
        string? message,
        CancellationToken cancellationToken)
    {
        RaiseTransferUpdated(new FileTransferLifecycleEventArgs
        {
            TransferId = transferId,
            OperationId = operationId,
            Direction = direction,
            PeerDeviceId = peerDeviceId,
            FileName = fileName,
            ByteSize = byteSize,
            State = "failed",
            FailureReason = failureReason,
            Message = message
        });

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

    private async Task TrySendCancelAsync(
        string peerDeviceId,
        string transferId,
        string failureReason,
        string message,
        CancellationToken cancellationToken)
    {
        try
        {
            var envelope = new
            {
                rift = "0.1-draft",
                type = "file.cancel",
                messageId = Guid.NewGuid().ToString("D"),
                sourceDeviceId = _identityManager.GetDeviceId(),
                payload = new
                {
                    transferId,
                    failureReason,
                    message
                }
            };

            await SendProtectedMessageAsync(peerDeviceId, EncodeEnvelope(envelope), cancellationToken).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            _logger.LogDebug(ex, "Best-effort file.cancel failed for {TransferId}.", transferId);
        }
    }

    private void ResetIncomingStagingRoot()
    {
        if (Directory.Exists(_incomingStagingRoot))
        {
            Directory.Delete(_incomingStagingRoot, recursive: true);
        }
        CreatePrivateDirectory(_incomingStagingRoot);
    }

    private static void CreatePrivateDirectory(string path)
    {
        Directory.CreateDirectory(path);
        if (!OperatingSystem.IsWindows())
        {
            File.SetUnixFileMode(
                path,
                UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
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
            return 1;
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

    private int GetPeerFileTransferVersion(string deviceId) =>
        _peerFileTransferVersions.TryGetValue(deviceId, out var version) ? version : 1;

    private bool PeerSupportsFileTransferVersion(string deviceId, int requiredVersion) =>
        GetPeerFileTransferVersion(deviceId) >= requiredVersion;

    private static void ValidateResumePosition(
        OutgoingTransferState transfer,
        int nextChunkIndex,
        long offset)
    {
        if (offset < 0 || offset > transfer.ByteSize)
        {
            throw new FileTransferFailureException("ProtocolError", -32001, "Resume offset was out of bounds.");
        }

        var chunkSize = transfer.AcceptedChunkSize ?? transfer.ChunkSize;
        var isFinalOffset = offset == transfer.ByteSize;
        var hasValidChunkIndex = transfer.ByteSize == 0
            ? nextChunkIndex is 0 or 1
            : nextChunkIndex == GetChunkIndexForOffset(offset, chunkSize);
        if ((!isFinalOffset && offset % chunkSize != 0) || !hasValidChunkIndex)
        {
            throw new FileTransferFailureException("ProtocolError", -32001, "Resume chunk index did not match offset.");
        }
    }

    private async Task SendCompleteAsync(
        OutgoingTransferState transfer,
        CancellationToken cancellationToken)
    {
        var envelope = new
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
                chunkCount = transfer.AcceptedChunkCount
            }
        };

        await SendProtectedMessageAsync(
            transfer.TargetDeviceId,
            EncodeEnvelope(envelope),
            cancellationToken).ConfigureAwait(false);
    }

    private async Task SendCommittedAsync(
        IncomingTransferState transfer,
        CancellationToken cancellationToken)
    {
        var envelope = new
        {
            rift = "0.1-draft",
            type = "file.committed",
            messageId = Guid.NewGuid().ToString("D"),
            sourceDeviceId = _identityManager.GetDeviceId(),
            payload = new
            {
                transferId = transfer.TransferId,
                byteSize = transfer.ByteSize,
                sha256 = transfer.ExpectedSha256
            }
        };

        await SendProtectedMessageAsync(
            transfer.SourceDeviceId,
            EncodeEnvelope(envelope),
            cancellationToken).ConfigureAwait(false);
    }

    private async Task FinalizeIncomingCommitAsync(
        IncomingTransferState transfer,
        string destinationPath,
        CancellationToken cancellationToken)
    {
        if (!_incomingTransfers.TryRemove(transfer.TransferId, out _))
        {
            return;
        }

        CleanupStagingDirectory(transfer.StagingDirectory);
        _operationService.TransitionOperation(transfer.OperationId, OperationState.Done);
        await NotifyTransferCompletedAsync(
            transfer.TransferId,
            transfer.OperationId,
            "incoming",
            transfer.SourceDeviceId,
            transfer.FileName,
            transfer.ByteSize,
            destinationPath,
            cancellationToken).ConfigureAwait(false);
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
            if (_transport.HasProtectedSession(peerDeviceId))
            {
                await _transport.SendAsync(peerDeviceId, frameBody, cancellationToken).ConfigureAwait(false);
                return;
            }
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
        if (_transport.HasProtectedSession(peerDeviceId))
        {
            return;
        }

        var peer = _trustStore.GetPeer(peerDeviceId);
        if (peer is null || peer.State != TrustState.Trusted)
        {
            throw new FileTransferFailureException("Unauthorized", -32004, $"Peer '{peerDeviceId}' is not trusted.");
        }

        var reconnectTask = _pendingTrustedReconnects.GetOrAdd(
            peerDeviceId,
            _ => ReconnectTrustedPeerAsync(peerDeviceId, peer, cancellationToken));

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

    private async Task ReconnectTrustedPeerAsync(string peerDeviceId, PeerIdentity peer, CancellationToken cancellationToken)
    {
        if (_transport.HasActiveSession(peerDeviceId))
        {
            await _transport.DisconnectPeerAsync(peerDeviceId, cancellationToken).ConfigureAwait(false);
        }

        if (peer.TrustedEndpoints.Count == 0)
        {
            await ReconnectTrustedPeerViaDiscoveryAsync(peerDeviceId, cancellationToken).ConfigureAwait(false);
            return;
        }

        await ReconnectTrustedPeerCoreAsync(peerDeviceId, peer, cancellationToken).ConfigureAwait(false);
    }

    private async Task ReconnectTrustedPeerCoreAsync(string peerDeviceId, PeerIdentity peer, CancellationToken cancellationToken)
    {
        Exception? lastError = null;
        foreach (var endpoint in peer.TrustedEndpoints)
        {
            try
            {
                await ConnectToEndpointWithRetryAsync(
                    peerDeviceId,
                    endpoint.Address,
                    endpoint.Port,
                    cancellationToken).ConfigureAwait(false);
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
                await ConnectToEndpointWithRetryAsync(
                    peerDeviceId,
                    endpoint.Address,
                    endpoint.Port,
                    cancellationToken).ConfigureAwait(false);
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

    private async Task ConnectToEndpointWithRetryAsync(
        string peerDeviceId,
        string address,
        int port,
        CancellationToken cancellationToken)
    {
        Exception? lastDuplicateRace = null;
        for (var attempt = 0; attempt < DuplicateReconnectRetryAttempts; attempt++)
        {
            try
            {
                using var timeoutCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
                timeoutCts.CancelAfter(TrustedReconnectTimeout);
                await _transport.ConnectToPeerAsync(address, port, timeoutCts.Token).ConfigureAwait(false);
                return;
            }
            catch (Exception ex) when (IsLikelyDuplicateBootstrapRace(ex))
            {
                lastDuplicateRace = ex;
                _logger.LogInformation(
                    ex,
                    "Trusted reconnect for peer {PeerDeviceId} hit a duplicate bootstrap race on {Address}:{Port}. Waiting briefly for an in-flight session before retry attempt {Attempt}/{MaxAttempts}.",
                    peerDeviceId,
                    address,
                    port,
                    attempt + 1,
                    DuplicateReconnectRetryAttempts);

                if (await WaitForProtectedSessionAsync(peerDeviceId, DuplicateReconnectRetryDelay, cancellationToken).ConfigureAwait(false))
                {
                    return;
                }
            }
        }

        if (lastDuplicateRace is not null)
        {
            throw lastDuplicateRace;
        }
    }

    private async Task<bool> WaitForProtectedSessionAsync(
        string peerDeviceId,
        TimeSpan timeout,
        CancellationToken cancellationToken)
    {
        var deadline = DateTimeOffset.UtcNow.Add(timeout);
        while (DateTimeOffset.UtcNow < deadline)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (_transport.HasProtectedSession(peerDeviceId))
            {
                return true;
            }

            await Task.Delay(25, cancellationToken).ConfigureAwait(false);
        }

        return _transport.HasProtectedSession(peerDeviceId);
    }

    private static bool IsLikelyDuplicateBootstrapRace(Exception ex)
    {
        return ex switch
        {
            InvalidOperationException invalidOperationException =>
                invalidOperationException.Message.Contains(
                    "Peer closed connection before sending session.hello.",
                    StringComparison.Ordinal),
            IOException ioException =>
                ioException.Message.Contains("unexpected EOF", StringComparison.OrdinalIgnoreCase) ||
                ioException.Message.Contains("0 bytes", StringComparison.OrdinalIgnoreCase),
            _ => false
        };
    }

    private static bool IsNoOpenSessionError(InvalidOperationException ex)
    {
        return ex.Message.Contains("No open session exists", StringComparison.Ordinal);
    }

    private static int GetChunkIndexForOffset(long offset, int chunkSize)
    {
        var completeChunks = offset / chunkSize;
        return checked((int)(completeChunks + (offset % chunkSize == 0 ? 0 : 1)));
    }

    private static bool IsRecoverableTransferInterruption(Exception exception, bool sendingProtectedMessage)
    {
        if (!sendingProtectedMessage)
        {
            return false;
        }

        return exception is IOException or InvalidOperationException ||
               exception is FileTransferFailureException { FailureReason: "PeerUnreachable" or "ConnectionLost" or "Timeout" };
    }

    private static string GetTerminalSendFailureReason(Exception exception) => exception switch
    {
        FileNotFoundException or DirectoryNotFoundException => "ProtocolError",
        UnauthorizedAccessException or IOException => "PolicyDenied",
        FileTransferFailureException failure => failure.FailureReason,
        InvalidOperationException => "InvalidTransition",
        TimeoutException => "Timeout",
        _ => "ProtocolError"
    };

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

    private void RaiseTransferUpdated(FileTransferLifecycleEventArgs args)
    {
        try
        {
            TransferUpdated?.Invoke(this, args);
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Unhandled exception from file transfer lifecycle subscriber for {TransferId}.", args.TransferId);
        }
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

    private static PendingFileCommitInfo ToPendingFileCommitInfo(IncomingTransferState transfer) => new()
    {
        TransferId = transfer.TransferId,
        OperationId = transfer.OperationId,
        PeerDeviceId = transfer.SourceDeviceId,
        FileName = transfer.FileName,
        MediaType = transfer.MediaType,
        ByteSize = transfer.ByteSize,
        Sha256 = transfer.ExpectedSha256,
        StagingPath = transfer.StagingPath,
        DestinationPath = transfer.DestinationPath
    };

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
            State = transfer.IsReadyToCommit ? "ready_to_commit" : operation?.State ?? "Unknown",
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
        public int NegotiatedVersion { get; init; } = 1;
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
        public int NextChunkIndex { get; set; }
        public string Sha256 { get; init; } = string.Empty;
        public int ChunkSize { get; init; }
        public int ChunkCount { get; init; }
        public int? AcceptedChunkSize { get; set; }
        public int AcceptedChunkCount { get; set; }
        public DateTimeOffset ExpiresAt { get; init; }
        public CancellationTokenSource SendCancellation { get; init; } = new();
        public Task? SendTask { get; set; }
        public bool RequiresCommitAcknowledgement { get; set; }
        public TaskCompletionSource CommitAcknowledgement { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
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
        public int NegotiatedVersion { get; init; } = 1;
        public bool IsReadyToCommit { get; set; }
        public bool IsLocallyCommitted { get; set; }
        public string? CommittedDestinationPath { get; set; }
        public SemaphoreSlim CommitGate { get; } = new(1, 1);
    }
}
