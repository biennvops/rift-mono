using Microsoft.Extensions.Logging.Abstractions;
using Rift.Daemon.Core;
using Rift.Daemon.Core.Interfaces;

namespace Rift.Daemon.Tests.Core;

public sealed class OperationServiceTests
{
    [Fact]
    public void TransitionOperation_AcceptsValidLifecycle()
    {
        var service = new OperationService(logger: NullLogger<OperationService>.Instance);

        service.CreateOperation("op-1", "clipboard.fetch", "rift-local", "rift-peer");
        service.TransitionOperation("op-1", OperationState.Pending);
        service.TransitionOperation("op-1", OperationState.Dispatched);
        service.TransitionOperation("op-1", OperationState.Active);
        var completed = service.TransitionOperation("op-1", OperationState.Done);

        Assert.Equal("Done", completed.State);
        Assert.Equal(4, completed.Transitions.Count);
    }

    [Fact]
    public void TransitionOperation_RejectsOutOfOrderTransition()
    {
        var service = new OperationService(logger: NullLogger<OperationService>.Instance);

        service.CreateOperation("op-2", "clipboard.fetch", "rift-local", "rift-peer");

        Assert.Throws<OperationTransitionException>(() =>
            service.TransitionOperation("op-2", OperationState.Active));
    }

    [Fact]
    public void TransitionOperation_TreatsDuplicateTerminalTransitionAsIdempotent()
    {
        var service = new OperationService(logger: NullLogger<OperationService>.Instance);

        service.CreateOperation("op-3", "clipboard.fetch", "rift-local", "rift-peer");
        service.TransitionOperation("op-3", OperationState.Pending);
        service.TransitionOperation("op-3", OperationState.Dispatched);
        service.TransitionOperation("op-3", OperationState.Active);
        var failed = service.TransitionOperation("op-3", OperationState.Failed, "PeerUnreachable");
        var duplicate = service.TransitionOperation("op-3", OperationState.Failed, "PeerUnreachable");

        Assert.Equal(failed.State, duplicate.State);
        Assert.Equal(4, duplicate.Transitions.Count);
    }

    [Fact]
    public void TransitionOperation_RejectsConflictingTerminalTransition()
    {
        var service = new OperationService(logger: NullLogger<OperationService>.Instance);

        service.CreateOperation("op-4", "clipboard.fetch", "rift-local", "rift-peer");
        service.TransitionOperation("op-4", OperationState.Pending);
        service.TransitionOperation("op-4", OperationState.Dispatched);
        service.TransitionOperation("op-4", OperationState.Expired, "Timeout");

        Assert.Throws<OperationTransitionException>(() =>
            service.TransitionOperation("op-4", OperationState.Done));
    }

    [Fact]
    public void TransitionOperation_AcceptsCreatedToFailedShortcut()
    {
        var service = new OperationService(logger: NullLogger<OperationService>.Instance);

        service.CreateOperation("op-created-failed", "clipboard.fetch", "rift-local", "rift-peer");
        var failed = service.TransitionOperation("op-created-failed", OperationState.Failed, "PeerUnreachable");
        var duplicate = service.TransitionOperation("op-created-failed", OperationState.Failed, "PeerUnreachable");

        Assert.Equal("Failed", failed.State);
        Assert.Equal("PeerUnreachable", failed.FailureReason);
        Assert.Single(failed.Transitions);
        Assert.Equal(failed.State, duplicate.State);
    }

    [Fact]
    public void TransitionOperation_AcceptsExpiredAsTerminalState()
    {
        var service = new OperationService(logger: NullLogger<OperationService>.Instance);

        service.CreateOperation("op-5", "clipboard.fetch", "rift-local", "rift-peer");
        service.TransitionOperation("op-5", OperationState.Pending);
        service.TransitionOperation("op-5", OperationState.Dispatched);
        var expired = service.TransitionOperation("op-5", OperationState.Expired, "Timeout");

        Assert.Equal("Expired", expired.State);
        Assert.Equal("Timeout", expired.FailureReason);
        Assert.Equal(3, expired.Transitions.Count);
    }

    [Fact]
    public void ListOperations_PaginatesNewestFirst()
    {
        var service = new OperationService(logger: NullLogger<OperationService>.Instance);

        service.CreateOperation("op-a", "clipboard.fetch", "rift-local", "rift-peer-a");
        service.CreateOperation("op-b", "clipboard.fetch", "rift-local", "rift-peer-b");
        service.CreateOperation("op-c", "clipboard.fetch", "rift-local", "rift-peer-c");

        var paged = service.ListOperations(limit: 1, offset: 1);

        Assert.Equal(3, paged.Total);
        Assert.Single(paged.Operations);
        Assert.Equal("op-b", paged.Operations[0].OperationId);
    }

    [Fact]
    public void CreateOperation_PrunesOldestOperationsWhenRetentionLimitIsExceeded()
    {
        var service = new OperationService(
            logger: NullLogger<OperationService>.Instance,
            retentionLimit: 2);

        service.CreateOperation("op-oldest", "clipboard.fetch", "rift-local", "rift-peer-a");
        service.TransitionOperation("op-oldest", OperationState.Failed, "PeerUnreachable");
        service.CreateOperation("op-middle", "clipboard.fetch", "rift-local", "rift-peer-b");
        service.CreateOperation("op-newest", "clipboard.fetch", "rift-local", "rift-peer-c");

        var listed = service.ListOperations(limit: 10, offset: 0);

        Assert.Equal(2, listed.Total);
        Assert.Equal(["op-newest", "op-middle"], listed.Operations.Select(operation => operation.OperationId).ToArray());
        Assert.Throws<InvalidOperationException>(() => service.GetOperation("op-oldest"));
        Assert.Equal("op-middle", service.GetOperation("op-middle").OperationId);
        Assert.Equal("op-newest", service.GetOperation("op-newest").OperationId);
    }

    [Fact]
    public void CreateOperation_DoesNotPruneInFlightOperationsWhenRetentionLimitIsExceeded()
    {
        var service = new OperationService(
            logger: NullLogger<OperationService>.Instance,
            retentionLimit: 2);

        service.CreateOperation("op-oldest", "clipboard.fetch", "rift-local", "rift-peer-a");
        service.TransitionOperation("op-oldest", OperationState.Pending);
        service.CreateOperation("op-middle", "clipboard.fetch", "rift-local", "rift-peer-b");
        service.CreateOperation("op-newest", "clipboard.fetch", "rift-local", "rift-peer-c");

        Assert.Equal(3, service.ListOperations(limit: 10, offset: 0).Total);
        Assert.Equal("op-oldest", service.GetOperation("op-oldest").OperationId);
        Assert.Equal("op-middle", service.GetOperation("op-middle").OperationId);
        Assert.Equal("op-newest", service.GetOperation("op-newest").OperationId);
    }
}
