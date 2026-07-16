using System.Threading.Tasks;

namespace Rift.Daemon.Core.Interfaces;

public sealed class FileTransferFailureException(string failureReason, int errorCode, string message) : Exception(message)
{
    public string FailureReason { get; } = failureReason;

    public int ErrorCode { get; } = errorCode;
}

public sealed class IncomingFileOfferInfo
{
    public string TransferId { get; init; } = string.Empty;
    public string SourceDeviceId { get; init; } = string.Empty;
    public string FileName { get; init; } = string.Empty;
    public string MediaType { get; init; } = string.Empty;
    public long ByteSize { get; init; }
    public string Sha256 { get; init; } = string.Empty;
    public int ChunkSize { get; init; }
    public int ChunkCount { get; init; }
    public string ExpiresAt { get; init; } = string.Empty;
}

public sealed class FileTransferInfo
{
    public string TransferId { get; init; } = string.Empty;
    public string OperationId { get; init; } = string.Empty;
    public string Direction { get; init; } = string.Empty;
    public string PeerDeviceId { get; init; } = string.Empty;
    public string FileName { get; init; } = string.Empty;
    public string MediaType { get; init; } = string.Empty;
    public long ByteSize { get; init; }
    public long BytesTransferred { get; init; }
    public string State { get; init; } = string.Empty;
    public string? FailureReason { get; init; }
    public string? DestinationPath { get; init; }
}

public sealed class OfferFileResult
{
    public string TransferId { get; init; } = string.Empty;
    public string OperationId { get; init; } = string.Empty;
    public string TargetDeviceId { get; init; } = string.Empty;
    public string FileName { get; init; } = string.Empty;
    public long ByteSize { get; init; }
    public int ChunkSize { get; init; }
    public int ChunkCount { get; init; }
}

public sealed class AcceptFileOfferResult
{
    public string TransferId { get; init; } = string.Empty;
    public string OperationId { get; init; } = string.Empty;
    public string DestinationPath { get; init; } = string.Empty;
}

public sealed class RejectFileOfferResult
{
    public string TransferId { get; init; } = string.Empty;
    public bool Rejected { get; init; }
}

public sealed class ListIncomingFileOffersResult
{
    public IReadOnlyList<IncomingFileOfferInfo> Offers { get; init; } = [];
}

public sealed class ListFileTransfersResult
{
    public IReadOnlyList<FileTransferInfo> Transfers { get; init; } = [];
}

public sealed class ReceivedFileOffer
{
    public string DeviceId { get; init; } = string.Empty;
    public string PayloadSourceDeviceId { get; init; } = string.Empty;
    public string TransferId { get; init; } = string.Empty;
    public string FileName { get; init; } = string.Empty;
    public string MediaType { get; init; } = string.Empty;
    public long ByteSize { get; init; }
    public string Sha256 { get; init; } = string.Empty;
    public int ChunkSize { get; init; }
    public int ChunkCount { get; init; }
    public long ExpiresInMs { get; init; }
    public string RequiredCapability { get; init; } = string.Empty;
}

public sealed class FileTransferLifecycleEventArgs : EventArgs
{
    public string TransferId { get; init; } = string.Empty;
    public string OperationId { get; init; } = string.Empty;
    public string Direction { get; init; } = string.Empty;
    public string PeerDeviceId { get; init; } = string.Empty;
    public string FileName { get; init; } = string.Empty;
    public long ByteSize { get; init; }
    public long BytesTransferred { get; init; }
    public string State { get; init; } = string.Empty;
    public string? FailureReason { get; init; }
    public string? Message { get; init; }
    public string? DestinationPath { get; init; }
}

public interface IFileTransferService
{
    event EventHandler<FileTransferLifecycleEventArgs>? TransferUpdated;

    Task<OfferFileResult> OfferFileAsync(
        string targetDeviceId,
        string localPath,
        string? fileName,
        string? mediaType,
        CancellationToken cancellationToken);

    Task<ListIncomingFileOffersResult> ListIncomingFileOffersAsync();

    Task<AcceptFileOfferResult> AcceptFileOfferAsync(
        string transferId,
        string destinationPath,
        bool overwrite,
        CancellationToken cancellationToken);

    Task<RejectFileOfferResult> RejectFileOfferAsync(
        string transferId,
        string failureReason,
        string? message,
        CancellationToken cancellationToken);

    Task<ListFileTransfersResult> ListFileTransfersAsync();

    Task HandleOfferReceivedAsync(ReceivedFileOffer offer, CancellationToken cancellationToken);

    Task HandleAcceptReceivedAsync(string deviceId, string transferId, string receivingDeviceId, int? chunkSize, CancellationToken cancellationToken);

    Task HandleRejectReceivedAsync(string deviceId, string transferId, string failureReason, string? message, CancellationToken cancellationToken);

    Task HandleChunkReceivedAsync(
        string deviceId,
        string transferId,
        int chunkIndex,
        long offset,
        int byteSize,
        string chunkSha256,
        string contentBase64,
        bool isLastChunk,
        CancellationToken cancellationToken);

    Task HandleCompleteReceivedAsync(
        string deviceId,
        string transferId,
        long byteSize,
        string sha256,
        int chunkCount,
        CancellationToken cancellationToken);

    Task HandleCancelReceivedAsync(
        string deviceId,
        string transferId,
        string failureReason,
        string? message,
        CancellationToken cancellationToken);
}
