using StreamJsonRpc;

namespace Rift.Daemon.Core.Interfaces;

public sealed class OperationTransitionException(string message) : Exception(message)
{
}

public enum OperationState
{
    Created,
    Pending,
    Dispatched,
    Active,
    Done,
    Failed,
    Expired
}

public sealed class OperationTransitionRecord
{
    public string From { get; init; } = string.Empty;
    public string To { get; init; } = string.Empty;
    public string At { get; init; } = string.Empty;
    public string? FailureReason { get; init; }
    public IReadOnlyDictionary<string, object?>? Details { get; init; }
}

public sealed class OperationRecord
{
    public string OperationId { get; init; } = string.Empty;
    public string OperationType { get; init; } = string.Empty;
    public string State { get; set; } = string.Empty;
    public string SourceDeviceId { get; init; } = string.Empty;
    public string DestinationDeviceId { get; init; } = string.Empty;
    public string CreatedAt { get; init; } = string.Empty;
    public string UpdatedAt { get; set; } = string.Empty;
    public string? FailureReason { get; set; }
    public IReadOnlyList<OperationTransitionRecord> Transitions { get; init; } = [];
}

public sealed class ListOperationsResult
{
    public IReadOnlyList<OperationRecord> Operations { get; init; } = [];
    public int Total { get; init; }
}

public interface IOperationService
{
    OperationRecord CreateOperation(string operationId, string operationType, string sourceDeviceId, string destinationDeviceId);

    OperationRecord TransitionOperation(
        string operationId,
        OperationState nextState,
        string? failureReason = null,
        IReadOnlyDictionary<string, object?>? details = null);

    ListOperationsResult ListOperations(int limit = 50, int offset = 0);

    OperationRecord GetOperation(string operationId);
}
