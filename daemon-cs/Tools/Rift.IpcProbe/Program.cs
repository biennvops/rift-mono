using System.IO.Pipes;
using System.Net.Sockets;
using StreamJsonRpc;

var method = args.Length > 0 ? args[0] : "rift.getDeviceInfo";
object parameters = method switch
{
    "rift.queryEventLog" => new { limit = 5 },
    _ => new { }
};

await using var stream = await ConnectAsync();
using var rpc = new JsonRpc(stream);
rpc.StartListening();

var result = await rpc.InvokeWithParameterObjectAsync<object>(method, parameters);
Console.WriteLine(result);

static async Task<Stream> ConnectAsync()
{
    if (OperatingSystem.IsWindows())
    {
        var pipe = new NamedPipeClientStream(
            ".",
            "rift-daemon-v0.1",
            PipeDirection.InOut,
            PipeOptions.Asynchronous);
        await pipe.ConnectAsync(5000);
        return pipe;
    }

    var socketPath = Environment.GetEnvironmentVariable("RIFT_DAEMON_SOCKET");
    if (string.IsNullOrWhiteSpace(socketPath))
    {
        var runtimeDirectory = Environment.GetEnvironmentVariable("XDG_RUNTIME_DIR");
        if (string.IsNullOrWhiteSpace(runtimeDirectory))
        {
            throw new InvalidOperationException(
                "XDG_RUNTIME_DIR or RIFT_DAEMON_SOCKET is required for Unix IPC probing.");
        }
        socketPath = Path.Combine(runtimeDirectory, "rift-daemon", "v0.1.sock");
    }

    using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(5));
    var socket = new Socket(AddressFamily.Unix, SocketType.Stream, ProtocolType.Unspecified);
    try
    {
        await socket.ConnectAsync(new UnixDomainSocketEndPoint(socketPath), timeout.Token);
        return new NetworkStream(socket, ownsSocket: true);
    }
    catch
    {
        socket.Dispose();
        throw;
    }
}
