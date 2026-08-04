using Rift.Daemon.Core.Networking;

namespace Rift.Daemon.Tests.Core;

public sealed class ParallelEndpointConnectorTests
{
    [Fact]
    public async Task FirstSuccessAsync_ReturnsFirstSuccessfulEndpointAndCancelsLosers()
    {
        var loserCancelled = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);

        var result = await ParallelEndpointConnector.FirstSuccessAsync(
            new[] { 1, 2 },
            async (endpoint, cancellationToken) =>
            {
                if (endpoint == 1)
                {
                    try
                    {
                        await Task.Delay(Timeout.InfiniteTimeSpan, cancellationToken);
                    }
                    catch (OperationCanceledException)
                    {
                        loserCancelled.SetResult(true);
                        throw;
                    }
                }

                await Task.Delay(20, cancellationToken);
                return endpoint;
            },
            TimeSpan.FromSeconds(1),
            CancellationToken.None);

        Assert.Equal(2, result.Endpoint);
        Assert.Equal(2, result.Result);
        await loserCancelled.Task.WaitAsync(TimeSpan.FromSeconds(1));
    }

    [Fact]
    public async Task FirstSuccessAsync_ThrowsWhenEveryEndpointFails()
    {
        var exception = await Assert.ThrowsAsync<InvalidOperationException>(() =>
            ParallelEndpointConnector.FirstSuccessAsync(
                new[] { 1, 2 },
                (endpoint, _) => Task.FromException<string>(
                    new InvalidOperationException($"endpoint {endpoint} failed")),
                TimeSpan.FromSeconds(1),
                CancellationToken.None));

        Assert.Contains("All parallel endpoint attempts failed", exception.Message);
        Assert.IsType<InvalidOperationException>(exception.InnerException);
    }
}
