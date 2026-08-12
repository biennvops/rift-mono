using StreamJsonRpc;

namespace Rift.Daemon.Core.Interfaces;

public interface IIpcNotificationService
{
    bool HasClients { get; }

    IDisposable RegisterClient(JsonRpc jsonRpc);

    Task NotifyAsync(string method, object parameters, CancellationToken cancellationToken = default);
}
