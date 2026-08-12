using System.Collections.Concurrent;
using Rift.Daemon.Core.Interfaces;
using StreamJsonRpc;

namespace Rift.Daemon.Core;

public sealed class IpcNotificationHub : IIpcNotificationService, IIpcNotificationActionExecutorService
{
    private readonly ConcurrentDictionary<int, JsonRpc> _clients = new();
    private readonly Lock _gate = new();
    private int _nextClientId;
    private int? _notificationActionExecutorClientId;

    public bool HasClients => !_clients.IsEmpty;

    public bool HasExecutor
    {
        get
        {
            lock (_gate)
            {
                if (_notificationActionExecutorClientId is not int clientId)
                {
                    return false;
                }

                if (_clients.ContainsKey(clientId))
                {
                    return true;
                }

                _notificationActionExecutorClientId = null;
                return false;
            }
        }
    }

    public IDisposable RegisterClient(JsonRpc jsonRpc)
    {
        ArgumentNullException.ThrowIfNull(jsonRpc);

        var clientId = Interlocked.Increment(ref _nextClientId);
        _clients[clientId] = jsonRpc;
        return new Registration(() => UnregisterClient(clientId));
    }

    public bool TryAcquire(JsonRpc jsonRpc)
    {
        ArgumentNullException.ThrowIfNull(jsonRpc);

        lock (_gate)
        {
            var clientId = FindClientId(jsonRpc);
            if (clientId is null)
            {
                return false;
            }

            if (_notificationActionExecutorClientId is int ownerClientId)
            {
                return ownerClientId == clientId;
            }

            _notificationActionExecutorClientId = clientId;
            return true;
        }
    }

    public bool Release(JsonRpc jsonRpc)
    {
        ArgumentNullException.ThrowIfNull(jsonRpc);

        lock (_gate)
        {
            if (_notificationActionExecutorClientId is not int clientId ||
                !_clients.TryGetValue(clientId, out var owner) ||
                !ReferenceEquals(owner, jsonRpc))
            {
                return false;
            }

            _notificationActionExecutorClientId = null;
            return true;
        }
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
                UnregisterClient(entry.Key);
            }
        }
    }

    public async Task<bool> NotifyExecutorAsync(
        string method,
        object parameters,
        CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(method);
        cancellationToken.ThrowIfCancellationRequested();

        KeyValuePair<int, JsonRpc> executor;
        lock (_gate)
        {
            if (_notificationActionExecutorClientId is not int clientId)
            {
                return false;
            }

            if (!_clients.TryGetValue(clientId, out var jsonRpc))
            {
                _notificationActionExecutorClientId = null;
                return false;
            }

            executor = new KeyValuePair<int, JsonRpc>(clientId, jsonRpc);
        }

        try
        {
            await executor.Value.NotifyWithParameterObjectAsync(method, parameters).ConfigureAwait(false);
            return true;
        }
        catch (Exception)
        {
            UnregisterClient(executor.Key);
            return false;
        }
    }

    private int? FindClientId(JsonRpc jsonRpc)
    {
        foreach (var entry in _clients)
        {
            if (ReferenceEquals(entry.Value, jsonRpc))
            {
                return entry.Key;
            }
        }

        return null;
    }

    private void UnregisterClient(int clientId)
    {
        lock (_gate)
        {
            _clients.TryRemove(clientId, out _);
            if (_notificationActionExecutorClientId == clientId)
            {
                _notificationActionExecutorClientId = null;
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

public sealed class IpcNotificationActionExecutorRpc(
    IIpcNotificationActionExecutorService executorService,
    JsonRpc jsonRpc)
{
    [JsonRpcMethod("rift.acquireNotificationActionExecutor")]
    public Task<IReadOnlyDictionary<string, bool>> AcquireAsync() =>
        Task.FromResult<IReadOnlyDictionary<string, bool>>(
            new Dictionary<string, bool>
            {
                ["acquired"] = executorService.TryAcquire(jsonRpc)
            });

    [JsonRpcMethod("rift.releaseNotificationActionExecutor")]
    public Task<IReadOnlyDictionary<string, bool>> ReleaseAsync() =>
        Task.FromResult<IReadOnlyDictionary<string, bool>>(
            new Dictionary<string, bool>
            {
                ["released"] = executorService.Release(jsonRpc)
            });
}
