namespace Rift.Daemon.Core.Interfaces;

public sealed class SendQueueItemInfo
{
    public string QueueItemId { get; init; } = string.Empty;
    public string Status { get; init; } = string.Empty;
    public string? TargetDeviceId { get; init; }
    public string LocalPath { get; init; } = string.Empty;
    public string FileName { get; init; } = string.Empty;
    public string MediaType { get; init; } = string.Empty;
    public long ByteSize { get; init; }
    public string? CurrentOperationId { get; init; }
    public string? LastTransferId { get; init; }
    public string? FailureReason { get; init; }
    public string? FailureMessage { get; init; }
    public string CreatedAt { get; init; } = string.Empty;
    public string UpdatedAt { get; init; } = string.Empty;
    public string? Origin { get; init; }
}

public sealed class EnqueueFileSendResult
{
    public string QueueItemId { get; init; } = string.Empty;
    public string Status { get; init; } = string.Empty;
    public string? TargetDeviceId { get; init; }
}

public sealed class ListSendQueueResult
{
    public IReadOnlyList<SendQueueItemInfo> Items { get; init; } = [];
}

public sealed class RemoveSendQueueItemResult
{
    public string QueueItemId { get; init; } = string.Empty;
    public bool Removed { get; init; }
}

public sealed class SendQueueFailureException(string failureReason, int errorCode, string message) : Exception(message)
{
    public string FailureReason { get; } = failureReason;

    public int ErrorCode { get; } = errorCode;
}

public interface ISendQueueService
{
    Task<EnqueueFileSendResult> EnqueueFileSendAsync(
        string localPath,
        string? fileName,
        string? mediaType,
        string? targetDeviceId,
        string? origin,
        CancellationToken cancellationToken);

    Task<ListSendQueueResult> ListSendQueueAsync(CancellationToken cancellationToken);

    Task<SendQueueItemInfo> GetSendQueueItemAsync(string queueItemId, CancellationToken cancellationToken);

    Task<SendQueueItemInfo> AssignSendQueueTargetAsync(
        string queueItemId,
        string targetDeviceId,
        CancellationToken cancellationToken);

    Task<SendQueueItemInfo> RetrySendQueueItemAsync(string queueItemId, CancellationToken cancellationToken);

    Task<RemoveSendQueueItemResult> RemoveSendQueueItemAsync(string queueItemId, CancellationToken cancellationToken);
}
