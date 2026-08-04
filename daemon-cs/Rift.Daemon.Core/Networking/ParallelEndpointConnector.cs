namespace Rift.Daemon.Core.Networking;

internal static class ParallelEndpointConnector
{
    internal static async Task<(TEndpoint Endpoint, TResult Result)> FirstSuccessAsync<TEndpoint, TResult>(
        IReadOnlyList<TEndpoint> endpoints,
        Func<TEndpoint, CancellationToken, Task<TResult>> attempt,
        TimeSpan timeout,
        CancellationToken cancellationToken)
    {
        if (endpoints.Count == 0)
        {
            throw new InvalidOperationException("At least one endpoint is required.");
        }

        using var attemptsCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        var pending = endpoints
            .Select(endpoint => AttemptAsync(endpoint, attempt, timeout, attemptsCts.Token))
            .ToList();
        Exception? lastError = null;

        try
        {
            while (pending.Count > 0)
            {
                cancellationToken.ThrowIfCancellationRequested();
                var completed = await Task.WhenAny(pending).ConfigureAwait(false);
                pending.Remove(completed);
                var result = await completed.ConfigureAwait(false);
                if (result.Error is null)
                {
                    attemptsCts.Cancel();
                    return (result.Endpoint, result.Result!);
                }

                lastError = result.Error;
            }
        }
        finally
        {
            attemptsCts.Cancel();
            try
            {
                await Task.WhenAll(pending).ConfigureAwait(false);
            }
            catch
            {
                // AttemptAsync converts endpoint failures into results. This is
                // only a guard for cancellation or an unexpected callback error.
            }
        }

        cancellationToken.ThrowIfCancellationRequested();
        throw new InvalidOperationException("All parallel endpoint attempts failed.", lastError);
    }

    private static async Task<AttemptResult<TEndpoint, TResult>> AttemptAsync<TEndpoint, TResult>(
        TEndpoint endpoint,
        Func<TEndpoint, CancellationToken, Task<TResult>> attempt,
        TimeSpan timeout,
        CancellationToken cancellationToken)
    {
        try
        {
            using var timeoutCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            timeoutCts.CancelAfter(timeout);
            var result = await attempt(endpoint, timeoutCts.Token).ConfigureAwait(false);
            return new AttemptResult<TEndpoint, TResult>(endpoint, result, null);
        }
        catch (Exception ex)
        {
            return new AttemptResult<TEndpoint, TResult>(endpoint, default, ex);
        }
    }

    private sealed record AttemptResult<TEndpoint, TResult>(
        TEndpoint Endpoint,
        TResult? Result,
        Exception? Error);
}
