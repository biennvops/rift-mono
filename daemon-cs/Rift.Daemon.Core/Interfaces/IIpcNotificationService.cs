using StreamJsonRpc;

namespace Rift.Daemon.Core.Interfaces;

public interface IIpcNotificationService
{
    bool HasClients { get; }

    IDisposable RegisterClient(JsonRpc jsonRpc);

    Task NotifyAsync(string method, object parameters, CancellationToken cancellationToken = default);
}

public interface IIpcNotificationActionExecutorService
{
    event EventHandler? ExecutorUnavailable;

    bool HasExecutor { get; }

    bool TryAcquire(JsonRpc jsonRpc);

    bool Release(JsonRpc jsonRpc);

    Task<bool> NotifyExecutorAsync(
        string method,
        object parameters,
        CancellationToken cancellationToken = default);
}
