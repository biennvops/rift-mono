using System.Net.Sockets;
using StreamJsonRpc;
using Rift.Daemon.Core;
using Rift.Daemon.Core.Interfaces;

namespace Rift.Daemon.macOS;

public class MacIpcListener(ILogger<MacIpcListener> logger) : IIpcListener, IDisposable
{
    private const string SocketDirName = "rift-daemon";
    private const string SocketFileName = "v0.1.sock";
    internal const int MacOsSunPathLimit = 104;

    private Socket? _listenSocket;
    private string? _socketPath;

    public static void EnsureNoDuplicateInstance()
    {
        var socketPath = ResolveSocketPath();
        var socketDir = Path.GetDirectoryName(socketPath)!;

        EnsureDirectoryWithMode(socketDir);

        if (!File.Exists(socketPath))
            return;

        using var probe = new Socket(AddressFamily.Unix, SocketType.Stream, ProtocolType.Unspecified);
        try
        {
            probe.Connect(new UnixDomainSocketEndPoint(socketPath));
            probe.Shutdown(SocketShutdown.Both);
            throw new InvalidOperationException(
                $"Another rift-daemon instance is already listening on {socketPath}");
        }
        catch (SocketException ex) when (ex.SocketErrorCode == SocketError.ConnectionRefused)
        {
            File.Delete(socketPath);
        }
        catch (SocketException)
        {
            File.Delete(socketPath);
        }
    }

    public async Task ListenAsync(CancellationToken stoppingToken)
    {
        _socketPath = ResolveSocketPath();
        var socketDir = Path.GetDirectoryName(_socketPath)!;

        EnsureDirectoryWithMode(socketDir);
        HandleExistingSocket(_socketPath);

        _listenSocket = new Socket(AddressFamily.Unix, SocketType.Stream, ProtocolType.Unspecified);

        try
        {
            _listenSocket.Bind(new UnixDomainSocketEndPoint(_socketPath));
            File.SetUnixFileMode(_socketPath,
                UnixFileMode.UserRead | UnixFileMode.UserWrite);

            _listenSocket.Listen(backlog: 8);

            logger.LogInformation("Listening for IPC connections on {path}", _socketPath);

            while (!stoppingToken.IsCancellationRequested)
            {
                try
                {
                    var client = await _listenSocket.AcceptAsync(stoppingToken);
                    logger.LogInformation("Client connected to IPC socket.");
                    _ = Task.Run(() => HandleClientAsync(client, stoppingToken), stoppingToken);
                }
                catch (OperationCanceledException)
                {
                    break;
                }
                catch (ObjectDisposedException)
                {
                    break;
                }
            }
        }
        catch (OperationCanceledException)
        {
            // Normal shutdown
        }
        finally
        {
            CleanupSocketFile();
        }
    }

    internal static string ResolveSocketPath()
    {
        var tmpDir = Environment.GetEnvironmentVariable("TMPDIR");
        string primary;

        if (!string.IsNullOrEmpty(tmpDir))
        {
            primary = Path.Combine(tmpDir, SocketDirName, SocketFileName);
            if (primary.Length < MacOsSunPathLimit)
                return primary;
        }

        var uid = Interop.GetUid().ToString();
        var fallback = Path.Combine("/tmp", $"rift-daemon-{uid}", SocketFileName);

        if (fallback.Length >= MacOsSunPathLimit)
            throw new InvalidOperationException(
                $"Socket path exceeds macOS sun_path limit of {MacOsSunPathLimit} characters: {fallback}");

        return fallback;
    }

    private static void EnsureDirectoryWithMode(string dirPath)
    {
        Directory.CreateDirectory(dirPath);
        File.SetUnixFileMode(dirPath,
            UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
    }

    private void HandleExistingSocket(string path)
    {
        if (!File.Exists(path))
            return;

        using var probe = new Socket(AddressFamily.Unix, SocketType.Stream, ProtocolType.Unspecified);
        try
        {
            probe.Connect(new UnixDomainSocketEndPoint(path));
            probe.Shutdown(SocketShutdown.Both);
            throw new InvalidOperationException(
                $"Another rift-daemon instance is already listening on {path}");
        }
        catch (SocketException ex) when (ex.SocketErrorCode == SocketError.ConnectionRefused)
        {
            logger.LogInformation("Removing stale socket file at {path}", path);
            File.Delete(path);
        }
        catch (SocketException ex)
        {
            logger.LogWarning(ex,
                "Unexpected error probing existing socket at {path} (SocketError={error}), treating as stale",
                path, ex.SocketErrorCode);
            File.Delete(path);
        }
    }

    private async Task HandleClientAsync(Socket client, CancellationToken stoppingToken)
    {
        try
        {
            await using var stream = new NetworkStream(client, ownsSocket: true);
            using var jsonRpc = JsonRpc.Attach(stream, new RiftApiHandler());
            await jsonRpc.Completion;
            logger.LogInformation("IPC client disconnected.");
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Error handling IPC client.");
        }
    }

    private void CleanupSocketFile()
    {
        if (_socketPath != null && File.Exists(_socketPath))
        {
            try
            {
                File.Delete(_socketPath);
                logger.LogInformation("Cleaned up socket file at {path}", _socketPath);
            }
            catch (Exception ex)
            {
                logger.LogWarning(ex, "Failed to clean up socket file at {path}", _socketPath);
            }
        }
    }

    public void Dispose()
    {
        _listenSocket?.Dispose();
        CleanupSocketFile();
    }
}

internal static class Interop
{
    [System.Runtime.InteropServices.DllImport("libc")]
    private static extern uint getuid();

    public static uint GetUid() => getuid();
}
