using Rift.Daemon.Core.Networking;

namespace Rift.Daemon.Tests.Core;

public sealed class SessionWriteGateTests
{
    [Fact]
    public async Task RunAsync_SerializesConcurrentOperations()
    {
        using var gate = new SessionWriteGate();
        var operationStarted = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var releaseFirst = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var overlapDetected = false;
        var activeWriters = 0;

        var first = gate.RunAsync(async cancellationToken =>
        {
            if (Interlocked.Increment(ref activeWriters) != 1)
            {
                overlapDetected = true;
            }

            operationStarted.SetResult();
            await releaseFirst.Task.WaitAsync(cancellationToken);
            Interlocked.Decrement(ref activeWriters);
        }, CancellationToken.None);

        await operationStarted.Task;

        var secondEntered = false;
        var second = gate.RunAsync(_ =>
        {
            secondEntered = true;
            if (Interlocked.Increment(ref activeWriters) != 1)
            {
                overlapDetected = true;
            }

            Interlocked.Decrement(ref activeWriters);
            return Task.CompletedTask;
        }, CancellationToken.None);

        await Task.Delay(50);
        Assert.False(secondEntered);

        releaseFirst.SetResult();
        await Task.WhenAll(first, second);

        Assert.True(secondEntered);
        Assert.False(overlapDetected);
    }
}
