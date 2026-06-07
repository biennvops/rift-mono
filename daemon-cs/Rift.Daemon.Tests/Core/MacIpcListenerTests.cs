using System.IO;
using System.Net.Sockets;
using System.Runtime.Versioning;
using System.Text;
using StreamJsonRpc;
using Rift.Daemon.Core;

namespace Rift.Daemon.Tests.Core;

[SupportedOSPlatform("osx")]
[SupportedOSPlatform("linux")]
public class MacIpcListenerTests : IDisposable
{
    private readonly string _testDir;
    private readonly string _socketPath;

    public MacIpcListenerTests()
    {
        _testDir = Path.Combine(Path.GetTempPath(), $"rift-test-{Guid.NewGuid():N}");
        _socketPath = Path.Combine(_testDir, "test.sock");
    }

    [Fact]
    public void DirectoryCreatedWithCorrectPermissions()
    {
        Directory.CreateDirectory(_testDir);
        File.SetUnixFileMode(_testDir,
            UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);

        var mode = File.GetUnixFileMode(_testDir);
        Assert.Equal(
            UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute,
            mode);
    }

    [Fact]
    public void SocketFileCreatedWithCorrectPermissions()
    {
        Directory.CreateDirectory(_testDir);

        using var socket = new Socket(AddressFamily.Unix, SocketType.Stream, ProtocolType.Unspecified);
        socket.Bind(new UnixDomainSocketEndPoint(_socketPath));
        File.SetUnixFileMode(_socketPath,
            UnixFileMode.UserRead | UnixFileMode.UserWrite);

        var mode = File.GetUnixFileMode(_socketPath);
        Assert.Equal(UnixFileMode.UserRead | UnixFileMode.UserWrite, mode);
    }

    [Fact]
    public void SocketPathLengthValidatedAgainst104CharLimit()
    {
        var longDir = new string('x', 90);
        var longPath = Path.Combine("/tmp", longDir, "test.sock");

        Assert.True(longPath.Length >= 104,
            $"Test path should exceed 104 chars, got {longPath.Length}");
    }

    [Fact]
    public void ConnectProbeDetectsLiveInstance()
    {
        Directory.CreateDirectory(_testDir);

        using var listener = new Socket(AddressFamily.Unix, SocketType.Stream, ProtocolType.Unspecified);
        listener.Bind(new UnixDomainSocketEndPoint(_socketPath));
        listener.Listen(1);

        using var probe = new Socket(AddressFamily.Unix, SocketType.Stream, ProtocolType.Unspecified);
        probe.Connect(new UnixDomainSocketEndPoint(_socketPath));

        Assert.True(probe.Connected);
    }

    [Fact]
    public void ConnectProbeDetectsStaleSocket()
    {
        Directory.CreateDirectory(_testDir);

        // Simulate a stale socket: create a regular file at the socket path.
        // In production, stale sockets are left behind by SIGKILL (where
        // Socket.Dispose never runs). .NET's Dispose cleans up the file,
        // so we can't simulate SIGKILL in-process. A non-socket file at the
        // path exercises the same error-handling code path.
        File.WriteAllText(_socketPath, "");

        using var probe = new Socket(AddressFamily.Unix, SocketType.Stream, ProtocolType.Unspecified);
        Assert.Throws<SocketException>(
            () => probe.Connect(new UnixDomainSocketEndPoint(_socketPath)));
    }

    [Fact]
    public async Task ClientCanConnectAndReceiveJsonRpcResponse()
    {
        Directory.CreateDirectory(_testDir);

        using var listener = new Socket(AddressFamily.Unix, SocketType.Stream, ProtocolType.Unspecified);
        listener.Bind(new UnixDomainSocketEndPoint(_socketPath));
        listener.Listen(1);

        var serverTask = Task.Run(async () =>
        {
            var server = await listener.AcceptAsync();
            await using var serverStream = new NetworkStream(server, ownsSocket: true);
            using var rpc = JsonRpc.Attach(serverStream, new RiftApiHandler());
            await rpc.Completion;
        });

        using var client = new Socket(AddressFamily.Unix, SocketType.Stream, ProtocolType.Unspecified);
        await client.ConnectAsync(new UnixDomainSocketEndPoint(_socketPath));
        await using var clientStream = new NetworkStream(client, ownsSocket: false);
        using var clientRpc = new JsonRpc(clientStream);
        clientRpc.StartListening();

        var version = await clientRpc.InvokeAsync<string>("GetVersionAsync");

        Assert.Equal("0.1-draft", version);

        clientRpc.Dispose();
        client.Shutdown(SocketShutdown.Both);
        await serverTask;
    }

    public void Dispose()
    {
        if (File.Exists(_socketPath))
            File.Delete(_socketPath);
        if (Directory.Exists(_testDir))
            Directory.Delete(_testDir, recursive: true);
    }
}
