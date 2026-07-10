using System.Collections.Concurrent;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;
using Rift.Daemon.Core.Interfaces;

namespace Rift.Daemon.Core;

public sealed class OperationService : IOperationService
{
    private readonly IIpcNotificationService? _ipcNotificationService;
    private readonly ISecurityEventLog? _securityEventLog;
    private readonly IIdentityManager? _identityManager;
    private readonly ILogger<OperationService> _logger;
    private readonly int _retentionLimit;
    private readonly object _gate = new();
    private readonly Dictionary<string, MutableOperationRecord> _operationsById = new(StringComparer.Ordinal);
    private readonly List<string> _operationOrder = [];

    public OperationService(
        IIpcNotificationService? ipcNotificationService = null,
        ISecurityEventLog? securityEventLog = null,
        IIdentityManager? identityManager = null,
        ILogger<OperationService>? logger = null,
        int retentionLimit = 200)
    {
        _ipcNotificationService = ipcNotificationService;
        _securityEventLog = securityEventLog;
        _identityManager = identityManager;
        _logger = logger ?? NullLogger<OperationService>.Instance;
        _retentionLimit = retentionLimit;
    }

    public OperationRecord CreateOperation(string operationId, string operationType, string sourceDeviceId, string destinationDeviceId)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(operationId);
        ArgumentException.ThrowIfNullOrWhiteSpace(operationType);

        lock (_gate)
        {
            if (_operationsById.TryGetValue(operationId, out var existing))
            {
                return existing.ToOperationRecord();
            }

            var now = DateTimeOffset.UtcNow.ToString("O");
            var created = new MutableOperationRecord
            {
                OperationId = operationId,
                OperationType = operationType,
                State = OperationState.Created,
                SourceDeviceId = sourceDeviceId,
                DestinationDeviceId = destinationDeviceId,
                CreatedAt = now,
                UpdatedAt = now
            };
            _operationsById[operationId] = created;
            _operationOrder.Add(operationId);
            PruneIfNeeded(protectOperationId: operationId);
            return created.ToOperationRecord();
        }
    }

    public OperationRecord TransitionOperation(
        string operationId,
        OperationState nextState,
        string? failureReason = null,
        IReadOnlyDictionary<string, object?>? details = null)
    {
        MutableOperationRecord operation;
        OperationState previousState;
        OperationRecord snapshot;

        lock (_gate)
        {
            if (!_operationsById.TryGetValue(operationId, out operation!))
            {
                throw new InvalidOperationException($"Operation '{operationId}' was not found.");
            }

            previousState = operation.State;
            if (IsTerminal(previousState))
            {
                if (previousState == nextState)
                {
                    return operation.ToOperationRecord();
                }

                throw new OperationTransitionException($"Invalid terminal transition from {ToWireName(previousState)} to {ToWireName(nextState)}.");
            }

            if (!IsAllowedTransition(previousState, nextState))
            {
                throw new OperationTransitionException($"Invalid transition from {ToWireName(previousState)} to {ToWireName(nextState)}.");
            }

            var now = DateTimeOffset.UtcNow.ToString("O");
            operation.State = nextState;
            operation.UpdatedAt = now;
            if (!string.IsNullOrWhiteSpace(failureReason))
            {
                operation.FailureReason = failureReason;
            }

            operation.Transitions.Add(new OperationTransitionRecord
            {
                From = ToWireName(previousState),
                To = ToWireName(nextState),
                At = now,
                FailureReason = failureReason,
                Details = details
            });

            snapshot = operation.ToOperationRecord();

            // Retention is best-effort. Never prune non-terminal operations, otherwise
            // in-flight transitions (timeouts/responses) can race and fail the RPC flow.
            // Also avoid pruning the operation we just transitioned, to preserve terminal
            // idempotency for late timers.
            PruneIfNeeded(protectOperationId: operationId);
        }

        NotifyTransition(snapshot, previousState, nextState, failureReason);
        return snapshot;
    }

    public ListOperationsResult ListOperations(int limit = 50, int offset = 0)
    {
        lock (_gate)
        {
            var normalizedOffset = Math.Max(offset, 0);
            var normalizedLimit = Math.Max(limit, 0);
            var operations = _operationOrder
                .AsEnumerable()
                .Reverse()
                .Skip(normalizedOffset)
                .Take(normalizedLimit)
                .Select(id => _operationsById[id].ToOperationRecord())
                .ToArray();

            return new ListOperationsResult
            {
                Operations = operations,
                Total = _operationsById.Count
            };
        }
    }

    public OperationRecord GetOperation(string operationId)
    {
        lock (_gate)
        {
            if (!_operationsById.TryGetValue(operationId, out var operation))
            {
                throw new InvalidOperationException($"Operation '{operationId}' was not found.");
            }

            return operation.ToOperationRecord();
        }
    }

    private void NotifyTransition(OperationRecord operation, OperationState previousState, OperationState nextState, string? failureReason)
    {
        if (_ipcNotificationService is not null)
        {
            _ = _ipcNotificationService.NotifyAsync(
                "rift.onOperationTransition",
                new
                {
                    operationId = operation.OperationId,
                    operationType = operation.OperationType,
                    previousState = ToWireName(previousState),
                    nextState = ToWireName(nextState),
                    failureReason
                }).ContinueWith(
                task =>
                {
                    if (task.IsFaulted)
                    {
                        _logger.LogWarning(task.Exception, "Failed to notify IPC clients about operation transition {OperationId}.", operation.OperationId);
                    }
                },
                CancellationToken.None,
                TaskContinuationOptions.ExecuteSynchronously,
                TaskScheduler.Default);
        }

        if (_securityEventLog is not null && _identityManager is not null)
        {
            _ = _securityEventLog.LogEventAsync(new SecurityEventRecord
            {
                EventType = SecurityEventTypes.OperationTransitioned,
                Severity = nextState is OperationState.Failed or OperationState.Expired ? SecurityEventSeverity.Warning : SecurityEventSeverity.Info,
                LocalDeviceId = _identityManager.GetDeviceId(),
                PeerDeviceId = operation.DestinationDeviceId,
                OperationId = operation.OperationId,
                Outcome = nextState is OperationState.Failed or OperationState.Expired ? SecurityEventOutcome.Failure : SecurityEventOutcome.Success,
                FailureReason = failureReason,
                Details = new Dictionary<string, object>
                {
                    ["operationType"] = operation.OperationType,
                    ["previousState"] = ToWireName(previousState),
                    ["nextState"] = ToWireName(nextState)
                }
            }).ContinueWith(
                task =>
                {
                    if (task.IsFaulted)
                    {
                        _logger.LogError(task.Exception, "Failed to persist operation transition event {OperationId}.", operation.OperationId);
                    }
                },
                CancellationToken.None,
                TaskContinuationOptions.ExecuteSynchronously,
                TaskScheduler.Default);
        }
    }

    private static bool IsTerminal(OperationState state) =>
        state is OperationState.Done or OperationState.Failed or OperationState.Expired;

    private static bool IsAllowedTransition(OperationState current, OperationState next) =>
        current switch
        {
            OperationState.Created => next is OperationState.Pending or OperationState.Failed,
            OperationState.Pending => next is OperationState.Dispatched or OperationState.Failed or OperationState.Expired,
            OperationState.Dispatched => next is OperationState.Active or OperationState.Failed or OperationState.Expired,
            OperationState.Active => next is OperationState.Done or OperationState.Failed or OperationState.Expired,
            _ => false
        };

    private static string ToWireName(OperationState state) => state switch
    {
        OperationState.Created => "Created",
        OperationState.Pending => "Pending",
        OperationState.Dispatched => "Dispatched",
        OperationState.Active => "Active",
        OperationState.Done => "Done",
        OperationState.Failed => "Failed",
        OperationState.Expired => "Expired",
        _ => throw new ArgumentOutOfRangeException(nameof(state), state, null)
    };

    private void PruneIfNeeded(string? protectOperationId = null)
    {
        while (_operationOrder.Count > _retentionLimit)
        {
            // Find the oldest terminal operation (excluding the protected one) and
            // prune that. If everything over the limit is still in-flight, keep it.
            var index = -1;
            for (var i = 0; i < _operationOrder.Count; i++)
            {
                var id = _operationOrder[i];
                if (protectOperationId is not null && StringComparer.Ordinal.Equals(id, protectOperationId))
                {
                    continue;
                }

                if (_operationsById.TryGetValue(id, out var op) && IsTerminal(op.State))
                {
                    index = i;
                    break;
                }
            }

            if (index < 0)
            {
                break;
            }

            var removed = _operationOrder[index];
            _operationOrder.RemoveAt(index);
            _operationsById.Remove(removed);
        }
    }

    private sealed class MutableOperationRecord
    {
        public string OperationId { get; init; } = string.Empty;
        public string OperationType { get; init; } = string.Empty;
        public OperationState State { get; set; }
        public string SourceDeviceId { get; init; } = string.Empty;
        public string DestinationDeviceId { get; init; } = string.Empty;
        public string CreatedAt { get; init; } = string.Empty;
        public string UpdatedAt { get; set; } = string.Empty;
        public string? FailureReason { get; set; }
        public List<OperationTransitionRecord> Transitions { get; } = [];

        public OperationRecord ToOperationRecord() => new()
        {
            OperationId = OperationId,
            OperationType = OperationType,
            State = ToWireName(State),
            SourceDeviceId = SourceDeviceId,
            DestinationDeviceId = DestinationDeviceId,
            CreatedAt = CreatedAt,
            UpdatedAt = UpdatedAt,
            FailureReason = FailureReason,
            Transitions = Transitions.ToArray()
        };
    }
}
