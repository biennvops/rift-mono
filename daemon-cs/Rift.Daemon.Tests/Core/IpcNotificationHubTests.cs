using Nerdbank.Streams;
using Rift.Daemon.Core;
using StreamJsonRpc;

namespace Rift.Daemon.Tests.Core;

public sealed class IpcNotificationHubTests
{
    [Fact]
    public async Task NotificationActionExecutor_DeliversToOnlyOneClientAndTransfersOnDisconnect()
    {
        var hub = new IpcNotificationHub();
        var first = CreateClient();
        var second = CreateClient();
        using var firstServer = first.Server;
        using var firstClient = first.Client;
        using var secondServer = second.Server;
        using var secondClient = second.Client;
        using var firstRegistration = hub.RegisterClient(firstServer);
        using var secondRegistration = hub.RegisterClient(secondServer);
        var executorUnavailableCount = 0;
        hub.ExecutorUnavailable += (_, _) => executorUnavailableCount++;

        Assert.True(hub.TryAcquire(firstServer));
        Assert.False(hub.TryAcquire(secondServer));

        Assert.True(await hub.NotifyExecutorAsync(
            "rift.onNotificationActionRequest",
            new { requestId = "request-1" }));

        Assert.Equal(1, await firstServer.InvokeAsync<int>("test.getActionRequestCount"));
        Assert.Equal(0, await secondServer.InvokeAsync<int>("test.getActionRequestCount"));

        firstRegistration.Dispose();
        Assert.Equal(1, executorUnavailableCount);
        Assert.True(hub.TryAcquire(secondServer));
        Assert.True(await hub.NotifyExecutorAsync(
            "rift.onNotificationActionRequest",
            new { requestId = "request-2" }));

        Assert.Equal(1, await firstServer.InvokeAsync<int>("test.getActionRequestCount"));
        Assert.Equal(1, await secondServer.InvokeAsync<int>("test.getActionRequestCount"));
    }

    private static (JsonRpc Server, JsonRpc Client) CreateClient()
    {
        var streams = FullDuplexStream.CreatePair();
        var server = JsonRpc.Attach(streams.Item1, new object());
        var client = JsonRpc.Attach(streams.Item2, new RecordingClient());
        return (server, client);
    }

    private sealed class RecordingClient
    {
        private int _actionRequestCount;

        [JsonRpcMethod("rift.onNotificationActionRequest")]
        public void OnNotificationActionRequest(string requestId)
        {
            Interlocked.Increment(ref _actionRequestCount);
        }

        [JsonRpcMethod("test.getActionRequestCount")]
        public int GetActionRequestCount() => Volatile.Read(ref _actionRequestCount);
    }
}
