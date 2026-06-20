using System.IO.Pipes;
using StreamJsonRpc;

var method = args.Length > 0 ? args[0] : "rift.getDeviceInfo";
object parameters = method switch
{
    "rift.queryEventLog" => new { limit = 5 },
    _ => new { }
};

using var pipe = new NamedPipeClientStream(
    ".",
    "rift-daemon-v0.1",
    PipeDirection.InOut,
    PipeOptions.Asynchronous);

await pipe.ConnectAsync(5000);

using var rpc = new JsonRpc(pipe);
rpc.StartListening();

var result = await rpc.InvokeWithParameterObjectAsync<object>(method, parameters);
Console.WriteLine(System.Text.Json.JsonSerializer.Serialize(result));
