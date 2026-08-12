using System.Collections.Concurrent;
using Rift.Daemon.Core.Interfaces;
using StreamJsonRpc;

namespace Rift.Daemon.Core;

public sealed class IpcNotificationHub : IIpcNotificationService
{
    private readonly ConcurrentDictionary<int, JsonRpc> _clients = new();
    private int _nextClientId;

    public bool HasClients => !_clients.IsEmpty;

    public IDisposable RegisterClient(JsonRpc jsonRpc)
    {
        ArgumentNullException.ThrowIfNull(jsonRpc);

        var clientId = Interlocked.Increment(ref _nextClientId);
        _clients[clientId] = jsonRpc;
        return new Registration(() => _clients.TryRemove(clientId, out _));
    }

    public async Task NotifyAsync(string method, object parameters, CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(method);

        var clients = _clients.ToArray();
        foreach (var entry in clients)
        {
            cancellationToken.ThrowIfCancellationRequested();

            try
            {
                await entry.Value.NotifyWithParameterObjectAsync(method, parameters).ConfigureAwait(false);
            }
            catch (Exception)
            {
                _clients.TryRemove(entry.Key, out _);
            }
        }
    }

    private sealed class Registration(Action disposeAction) : IDisposable
    {
        private Action? _disposeAction = disposeAction;

        public void Dispose()
        {
            Interlocked.Exchange(ref _disposeAction, null)?.Invoke();
        }
    }
}
