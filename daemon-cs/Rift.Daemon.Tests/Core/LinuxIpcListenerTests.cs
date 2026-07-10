using System.Net.Sockets;
using System.Runtime.Versioning;
using System.Text;
using StreamJsonRpc;
using Rift.Daemon.Core;
using Rift.Daemon.Linux;

namespace Rift.Daemon.Tests.Core;

[SupportedOSPlatform("osx")]
[SupportedOSPlatform("linux")]
public class LinuxIpcListenerTests : IDisposable
{
    private readonly string _testDir;
    private readonly string _socketPath;

    public LinuxIpcListenerTests()
    {
        _testDir = Path.Combine(Path.GetTempPath(), $"rift-test-{Guid.NewGuid():N}");
        _socketPath = Path.Combine(_testDir, "test.sock");
    }

    private static bool IsUnix => OperatingSystem.IsMacOS() || OperatingSystem.IsLinux();

    [Fact]
    public void FitsInSunPath_WithinLimit_ReturnsTrue()
    {
        Assert.True(LinuxIpcListener.FitsInSunPath("/tmp/rift-daemon/v0.1.sock"));
    }

    [Fact]
    public void FitsInSunPath_ExactlyAtLimit_ReturnsTrue()
    {
        // 107 bytes + 1 NUL = 108 = LinuxSunPathLimit
        var path = "/" + new string('a', 106);
        Assert.Equal(107, Encoding.UTF8.GetByteCount(path));
        Assert.True(LinuxIpcListener.FitsInSunPath(path));
    }

    [Fact]
    public void FitsInSunPath_ExceedsLimit_ReturnsFalse()
    {
        // 108 bytes + 1 NUL = 109 > 108
        var path = "/" + new string('a', 107);
        Assert.Equal(108, Encoding.UTF8.GetByteCount(path));
        Assert.False(LinuxIpcListener.FitsInSunPath(path));
    }

    [Fact]
    public void FitsInSunPath_NonAsciiExceedsLimit_ReturnsFalse()
    {
        // Each é is 2 UTF-8 bytes, so this is shorter by char count but long by byte count
        var path = "/" + new string('é', 54);
        Assert.True(path.Length < LinuxIpcListener.LinuxSunPathLimit);
        Assert.True(Encoding.UTF8.GetByteCount(path) + 1 > LinuxIpcListener.LinuxSunPathLimit);
        Assert.False(LinuxIpcListener.FitsInSunPath(path));
    }

    [Fact]
    public void ResolveSocketPath_UsesXdgRuntimeDir_WhenValid()
    {
        if (!IsUnix) return;

        // macOS temp paths can be long enough to exceed Linux sun_path limits.
        // Use a short path so this test actually exercises the XDG branch.
        var xdgDir = Path.Combine("/tmp", $"rift-test-xdg-{Guid.NewGuid():N}");
        Directory.CreateDirectory(xdgDir);
        File.SetUnixFileMode(xdgDir,
            UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);

        var prev = Environment.GetEnvironmentVariable("XDG_RUNTIME_DIR");
        try
        {
            Environment.SetEnvironmentVariable("XDG_RUNTIME_DIR", xdgDir);
            var result = LinuxIpcListener.ResolveSocketPath();
            Assert.StartsWith(xdgDir, result);
            Assert.EndsWith("v0.1.sock", result);
        }
        finally
        {
            Environment.SetEnvironmentVariable("XDG_RUNTIME_DIR", prev);
            try
            {
                Directory.Delete(xdgDir, recursive: true);
            }
            catch
            {
                // Best-effort cleanup; ignore races/permissions in CI.
            }
        }
    }

    [Fact]
    public void ResolveSocketPath_FallsBackToTmp_WhenXdgUnset()
    {
        if (!IsUnix) return;

        var prev = Environment.GetEnvironmentVariable("XDG_RUNTIME_DIR");
        try
        {
            Environment.SetEnvironmentVariable("XDG_RUNTIME_DIR", null);
            var result = LinuxIpcListener.ResolveSocketPath();
            Assert.StartsWith("/tmp/rift-daemon-", result);
        }
        finally
        {
            Environment.SetEnvironmentVariable("XDG_RUNTIME_DIR", prev);
        }
    }

    [Fact]
    public void ResolveSocketPath_FallsBackToTmp_WhenXdgNonexistent()
    {
        if (!IsUnix) return;

        var prev = Environment.GetEnvironmentVariable("XDG_RUNTIME_DIR");
        try
        {
            Environment.SetEnvironmentVariable("XDG_RUNTIME_DIR", "/nonexistent-xdg-dir");
            var result = LinuxIpcListener.ResolveSocketPath();
            Assert.StartsWith("/tmp/rift-daemon-", result);
        }
        finally
        {
            Environment.SetEnvironmentVariable("XDG_RUNTIME_DIR", prev);
        }
    }

    [Fact]
    public void ResolveSocketPath_FallsBackToTmp_WhenXdgNotWritable()
    {
        if (!IsUnix) return;

        var xdgDir = Path.Combine(_testDir, "xdg-readonly");
        Directory.CreateDirectory(xdgDir);
        File.SetUnixFileMode(xdgDir, UnixFileMode.UserRead | UnixFileMode.UserExecute);

        var prev = Environment.GetEnvironmentVariable("XDG_RUNTIME_DIR");
        try
        {
            Environment.SetEnvironmentVariable("XDG_RUNTIME_DIR", xdgDir);
            var result = LinuxIpcListener.ResolveSocketPath();
            Assert.StartsWith("/tmp/rift-daemon-", result);
        }
        finally
        {
            Environment.SetEnvironmentVariable("XDG_RUNTIME_DIR", prev);
        }
    }

    [Fact]
    public void DefaultValidateFallbackDirectory_WrongMode_ReturnsFalse()
    {
        if (!IsUnix) return;

        var dir = Path.Combine(_testDir, "wrong-mode");
        Directory.CreateDirectory(dir);
        File.SetUnixFileMode(dir,
            UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute |
            UnixFileMode.GroupRead | UnixFileMode.GroupExecute);

        Assert.False(LinuxIpcListener.DefaultValidateFallbackDirectory(dir));
    }

    [Fact]
    public void DefaultValidateFallbackDirectory_CorrectMode_ReturnsTrue()
    {
        if (!IsUnix) return;

        var dir = Path.Combine(_testDir, "correct-mode");
        Directory.CreateDirectory(dir);
        File.SetUnixFileMode(dir,
            UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);

        Assert.True(LinuxIpcListener.DefaultValidateFallbackDirectory(dir));
    }

    [Fact]
    public void EnsureFallbackDirectory_FailedValidation_Throws()
    {
        if (!IsUnix) return;

        var dir = Path.Combine(_testDir, "will-fail");
        Directory.CreateDirectory(dir);
        File.SetUnixFileMode(dir,
            UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);

        var ex = Assert.Throws<InvalidOperationException>(() =>
            LinuxIpcListener.EnsureFallbackDirectory(dir, _ => false));
        Assert.Contains("failed security validation", ex.Message);
    }

    [Fact]
    public void EnsureFallbackDirectory_PassedValidation_DoesNotThrow()
    {
        if (!IsUnix) return;

        var dir = Path.Combine(_testDir, "will-pass");
        Directory.CreateDirectory(dir);
        File.SetUnixFileMode(dir,
            UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);

        LinuxIpcListener.EnsureFallbackDirectory(dir, _ => true);
    }

    [Fact]
    public void ResolveSocketPath_InjectedValidatorRejects_Throws()
    {
        if (!IsUnix) return;

        var prev = Environment.GetEnvironmentVariable("XDG_RUNTIME_DIR");
        try
        {
            Environment.SetEnvironmentVariable("XDG_RUNTIME_DIR", null);
            var ex = Assert.Throws<InvalidOperationException>(() =>
                LinuxIpcListener.ResolveSocketPath(validateFallbackDir: _ => false));
            Assert.Contains("failed security validation", ex.Message);
        }
        finally
        {
            Environment.SetEnvironmentVariable("XDG_RUNTIME_DIR", prev);
        }
    }

    [Fact]
    public void ConnectProbeDetectsLiveInstance()
    {
        if (!IsUnix) return;

        Directory.CreateDirectory(_testDir);

        using var listener = new Socket(AddressFamily.Unix, SocketType.Stream, ProtocolType.Unspecified);
        listener.Bind(new UnixDomainSocketEndPoint(_socketPath));
        listener.Listen(1);

        using var probe = new Socket(AddressFamily.Unix, SocketType.Stream, ProtocolType.Unspecified);
        probe.Connect(new UnixDomainSocketEndPoint(_socketPath));

        Assert.True(probe.Connected);
    }

    [Fact]
    public void ConnectProbeToNonSocketFile_ThrowsSocketException()
    {
        if (!IsUnix) return;

        Directory.CreateDirectory(_testDir);
        File.WriteAllText(_socketPath, "");

        using var probe = new Socket(AddressFamily.Unix, SocketType.Stream, ProtocolType.Unspecified);
        Assert.Throws<SocketException>(
            () => probe.Connect(new UnixDomainSocketEndPoint(_socketPath)));
    }

    [Fact]
    public async Task ClientCanConnectAndReceiveJsonRpcResponse()
    {
        if (!IsUnix) return;

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
