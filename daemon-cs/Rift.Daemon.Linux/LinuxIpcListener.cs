using System.Net.Sockets;
using System.Text;
using StreamJsonRpc;
using Rift.Daemon.Core;
using Rift.Daemon.Core.Interfaces;

namespace Rift.Daemon.Linux;

public class LinuxIpcListener : IIpcListener, IDisposable
{
    private const string SocketDirName = "rift-daemon";
    private const string SocketFileName = "v0.1.sock";
    internal const int LinuxSunPathLimit = 108;

    private static readonly UnixFileMode Dir0700 =
        UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute;

    private readonly ILogger<LinuxIpcListener> _logger;
    private readonly Func<string, bool> _validateDirectory;

    private Socket? _listenSocket;
    private string? _socketPath;

    public LinuxIpcListener(ILogger<LinuxIpcListener> logger)
        : this(logger, DefaultValidateDirectory)
    {
    }

    internal LinuxIpcListener(ILogger<LinuxIpcListener> logger, Func<string, bool> validateDirectory)
    {
        _logger = logger;
        _validateDirectory = validateDirectory;
    }

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
            try
            {
                _listenSocket.Bind(new UnixDomainSocketEndPoint(_socketPath));
            }
            catch (SocketException ex) when (ex.SocketErrorCode == SocketError.AddressAlreadyInUse)
            {
                throw new InvalidOperationException(
                    $"Another rift-daemon instance is already listening on {_socketPath}", ex);
            }

            File.SetUnixFileMode(_socketPath,
                UnixFileMode.UserRead | UnixFileMode.UserWrite);

            _listenSocket.Listen(backlog: 8);

            _logger.LogInformation("Listening for IPC connections on {path}", _socketPath);

            while (!stoppingToken.IsCancellationRequested)
            {
                try
                {
                    var client = await _listenSocket.AcceptAsync(stoppingToken);
                    _logger.LogInformation("Client connected to IPC socket.");
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
        }
        finally
        {
            CleanupSocketFile();
        }
    }

    internal static string ResolveSocketPath()
    {
        var xdgRuntimeDir = Environment.GetEnvironmentVariable("XDG_RUNTIME_DIR");

        if (!string.IsNullOrEmpty(xdgRuntimeDir))
        {
            if (Directory.Exists(xdgRuntimeDir) && IsDirectoryWritable(xdgRuntimeDir))
            {
                var primary = Path.Combine(xdgRuntimeDir, SocketDirName, SocketFileName);
                if (FitsInSunPath(primary))
                    return primary;
            }
        }

        var uid = Interop.GetUid().ToString();
        var fallbackDir = Path.Combine("/tmp", $"rift-daemon-{uid}");
        var fallback = Path.Combine(fallbackDir, SocketFileName);

        if (!FitsInSunPath(fallback))
            throw new InvalidOperationException(
                $"Socket path exceeds Linux sun_path limit of {LinuxSunPathLimit} bytes: {fallback}");

        EnsureFallbackDirectory(fallbackDir);
        return fallback;
    }

    internal static bool FitsInSunPath(string path) =>
        Encoding.UTF8.GetByteCount(path) + 1 <= LinuxSunPathLimit;

    private static void EnsureFallbackDirectory(string dirPath)
    {
        if (Directory.Exists(dirPath))
        {
            var mode = File.GetUnixFileMode(dirPath);
            if (mode != Dir0700)
                throw new InvalidOperationException(
                    $"Fallback directory {dirPath} has mode {mode}, expected {Dir0700}. Refusing to start.");

            var probe = Path.Combine(dirPath, $".probe-{Guid.NewGuid():N}");
            try
            {
                File.WriteAllText(probe, "");
                File.Delete(probe);
            }
            catch (UnauthorizedAccessException)
            {
                throw new InvalidOperationException(
                    $"Fallback directory {dirPath} is not writable. Refusing to start.");
            }
        }
        else
        {
            Directory.CreateDirectory(dirPath);
            File.SetUnixFileMode(dirPath, Dir0700);
        }
    }

    private static bool IsDirectoryWritable(string dirPath)
    {
        var probe = Path.Combine(dirPath, $".probe-{Guid.NewGuid():N}");
        try
        {
            File.WriteAllText(probe, "");
            File.Delete(probe);
            return true;
        }
        catch (UnauthorizedAccessException)
        {
            return false;
        }
    }

    private static void EnsureDirectoryWithMode(string dirPath)
    {
        Directory.CreateDirectory(dirPath);
        File.SetUnixFileMode(dirPath, Dir0700);
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
            _logger.LogInformation("Removing stale socket file at {path}", path);
            File.Delete(path);
        }
        catch (SocketException ex)
        {
            throw new InvalidOperationException(
                $"Cannot probe existing socket at {path} (SocketError={ex.SocketErrorCode}). " +
                "Refusing to delete — resolve manually.", ex);
        }
    }

    private async Task HandleClientAsync(Socket client, CancellationToken stoppingToken)
    {
        try
        {
            await using var stream = new NetworkStream(client, ownsSocket: true);
            using var jsonRpc = JsonRpc.Attach(stream, new RiftApiHandler());
            await jsonRpc.Completion;
            _logger.LogInformation("IPC client disconnected.");
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Error handling IPC client.");
        }
    }

    private void CleanupSocketFile()
    {
        if (_socketPath != null && File.Exists(_socketPath))
        {
            try
            {
                File.Delete(_socketPath);
                _logger.LogInformation("Cleaned up socket file at {path}", _socketPath);
            }
            catch (Exception ex)
            {
                _logger.LogWarning(ex, "Failed to clean up socket file at {path}", _socketPath);
            }
        }
    }

    public void Dispose()
    {
        _listenSocket?.Dispose();
        CleanupSocketFile();
    }

    private static bool DefaultValidateDirectory(string dirPath) =>
        Directory.Exists(dirPath) && IsDirectoryWritable(dirPath);
}

internal static class Interop
{
    [System.Runtime.InteropServices.DllImport("libc")]
    private static extern uint getuid();

    public static uint GetUid() => getuid();
}
