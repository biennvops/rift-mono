using System.Diagnostics;
using System.Text.Json;

namespace Rift.Daemon.macOS;

internal interface IMacOSNotificationExtractorClient
{
    Task<MacOSExtractorStatus> GetStatusAsync(CancellationToken cancellationToken);
    Task<MacOSExtractorScanResult> ScanNotificationChangesAsync(long cursor, CancellationToken cancellationToken);
    Task<MacOSExtractorScanResult> RescanActiveNotificationsAsync(CancellationToken cancellationToken);
}

internal sealed class MacOSNotificationExtractorClient : IMacOSNotificationExtractorClient
{
    private const int MaximumResponseBytes = 1024 * 1024;
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);

    private readonly string _appPath;
    private readonly Func<string, string, string, string, CancellationToken, Task> _launchAsync;
    private readonly TimeSpan _requestTimeout;

    public MacOSNotificationExtractorClient()
        : this(ResolveAppPath(), LaunchThroughLaunchServicesAsync, TimeSpan.FromSeconds(10))
    {
    }

    internal MacOSNotificationExtractorClient(
        string appPath,
        Func<string, string, string, string, CancellationToken, Task> launchAsync,
        TimeSpan? requestTimeout = null)
    {
        _appPath = appPath;
        _launchAsync = launchAsync;
        _requestTimeout = requestTimeout ?? TimeSpan.FromSeconds(10);
    }

    public Task<MacOSExtractorStatus> GetStatusAsync(CancellationToken cancellationToken) =>
        SendAsync<MacOSExtractorStatus>("getStatus", cursor: null, cancellationToken);

    public Task<MacOSExtractorScanResult> ScanNotificationChangesAsync(long cursor, CancellationToken cancellationToken) =>
        SendAsync<MacOSExtractorScanResult>("scanNotificationChanges", Math.Max(0, cursor), cancellationToken);

    public Task<MacOSExtractorScanResult> RescanActiveNotificationsAsync(CancellationToken cancellationToken) =>
        SendAsync<MacOSExtractorScanResult>("rescanActiveNotifications", cursor: null, cancellationToken);

    private async Task<T> SendAsync<T>(string operation, long? cursor, CancellationToken cancellationToken)
    {
        if (!Directory.Exists(_appPath))
        {
            throw new MacOSExtractorException("extractorNotFound", "Rift Notification Extractor is not installed.");
        }

        var directory = Directory.CreateTempSubdirectory("rift-notification-client-");
        var requestPath = Path.Combine(directory.FullName, "request.json");
        var responsePath = Path.Combine(directory.FullName, "response.json");
        var errorPath = Path.Combine(directory.FullName, "error.txt");
        SetPrivateDirectoryMode(directory.FullName);

        try
        {
            var requestId = Guid.NewGuid().ToString("D");
            var request = JsonSerializer.Serialize(new
            {
                id = requestId,
                operation,
                cursor
            }, JsonOptions);
            await CreatePrivateFileAsync(requestPath, request + "\n", cancellationToken).ConfigureAwait(false);
            await CreatePrivateFileAsync(responsePath, string.Empty, cancellationToken).ConfigureAwait(false);
            await CreatePrivateFileAsync(errorPath, string.Empty, cancellationToken).ConfigureAwait(false);

            using var timeoutCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            timeoutCts.CancelAfter(_requestTimeout);
            try
            {
                await _launchAsync(_appPath, requestPath, responsePath, errorPath, timeoutCts.Token).ConfigureAwait(false);
                await WaitForResponseAsync(responsePath, timeoutCts.Token).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
            {
                throw new MacOSExtractorException("extractorTimeout", "Rift Notification Extractor did not respond in time.");
            }

            var responseLength = new FileInfo(responsePath).Length;
            if (responseLength > MaximumResponseBytes)
            {
                throw new MacOSExtractorException("responseTooLarge", "Rift Notification Extractor response exceeded 1 MiB.");
            }

            var responseJson = await File.ReadAllTextAsync(responsePath, cancellationToken).ConfigureAwait(false);
            ExtractorResponse? response;
            try
            {
                response = JsonSerializer.Deserialize<ExtractorResponse>(responseJson, JsonOptions);
            }
            catch (JsonException)
            {
                throw new MacOSExtractorException("invalidResponse", "Rift Notification Extractor returned invalid JSON.");
            }

            if (response is null)
            {
                throw new MacOSExtractorException("invalidResponse", "Rift Notification Extractor returned an empty response.");
            }
            if (!string.Equals(response.Id, requestId, StringComparison.Ordinal))
            {
                throw new MacOSExtractorException("invalidResponse", "Rift Notification Extractor response ID did not match the request.");
            }
            if (!response.Ok)
            {
                throw new MacOSExtractorException(
                    response.Error?.Code ?? "extractorError",
                    response.Error?.Message ?? "Rift Notification Extractor reported an error.");
            }

            try
            {
                return response.Result.Deserialize<T>(JsonOptions)
                    ?? throw new JsonException();
            }
            catch (JsonException)
            {
                throw new MacOSExtractorException("invalidResponse", "Rift Notification Extractor returned an invalid result.");
            }
        }
        finally
        {
            try
            {
                directory.Delete(recursive: true);
            }
            catch
            {
            }
        }
    }

    private static async Task LaunchThroughLaunchServicesAsync(
        string appPath,
        string requestPath,
        string responsePath,
        string errorPath,
        CancellationToken cancellationToken)
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = "/usr/bin/open",
            UseShellExecute = false,
            CreateNoWindow = true
        };
        startInfo.ArgumentList.Add("-n");
        startInfo.ArgumentList.Add("-g");
        startInfo.ArgumentList.Add("-a");
        startInfo.ArgumentList.Add(appPath);
        startInfo.ArgumentList.Add("--stdin");
        startInfo.ArgumentList.Add(requestPath);
        startInfo.ArgumentList.Add("--stdout");
        startInfo.ArgumentList.Add(responsePath);
        startInfo.ArgumentList.Add("--stderr");
        startInfo.ArgumentList.Add(errorPath);

        using var process = new Process { StartInfo = startInfo };
        process.Start();
        await process.WaitForExitAsync(cancellationToken).ConfigureAwait(false);
        if (process.ExitCode != 0)
        {
            var error = await File.ReadAllTextAsync(errorPath, cancellationToken).ConfigureAwait(false);
            throw new MacOSExtractorException(
                "launchFailed",
                string.IsNullOrWhiteSpace(error)
                    ? "Failed to launch Rift Notification Extractor."
                    : error.Trim());
        }
    }

    private static async Task WaitForResponseAsync(string responsePath, CancellationToken cancellationToken)
    {
        while (true)
        {
            var length = new FileInfo(responsePath).Length;
            if (length > MaximumResponseBytes)
            {
                throw new MacOSExtractorException("responseTooLarge", "Rift Notification Extractor response exceeded 1 MiB.");
            }
            if (length > 0)
            {
                await using var stream = new FileStream(
                    responsePath,
                    FileMode.Open,
                    FileAccess.Read,
                    FileShare.ReadWrite | FileShare.Delete);
                stream.Seek(-1, SeekOrigin.End);
                if (stream.ReadByte() == '\n')
                {
                    return;
                }
            }

            await Task.Delay(TimeSpan.FromMilliseconds(50), cancellationToken).ConfigureAwait(false);
        }
    }

    private static async Task CreatePrivateFileAsync(string path, string content, CancellationToken cancellationToken)
    {
        await using (File.Create(path))
        {
        }
        if (!OperatingSystem.IsWindows())
        {
            File.SetUnixFileMode(path, UnixFileMode.UserRead | UnixFileMode.UserWrite);
        }
        await File.WriteAllTextAsync(path, content, cancellationToken).ConfigureAwait(false);
    }

    private static void SetPrivateDirectoryMode(string path)
    {
        if (!OperatingSystem.IsWindows())
        {
            File.SetUnixFileMode(path, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
        }
    }

    private static string ResolveAppPath()
    {
        var configuredPath = Environment.GetEnvironmentVariable("RIFT_NOTIFICATION_EXTRACTOR_APP");
        if (!string.IsNullOrWhiteSpace(configuredPath))
        {
            return configuredPath;
        }

        return Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            "Applications",
            "Rift Notification Extractor.app");
    }

    private sealed class ExtractorResponse
    {
        public string Id { get; init; } = string.Empty;
        public bool Ok { get; init; }
        public JsonElement Result { get; init; }
        public ExtractorError? Error { get; init; }
    }

    private sealed class ExtractorError
    {
        public string Code { get; init; } = string.Empty;
        public string Message { get; init; } = string.Empty;
    }
}

internal sealed class MacOSExtractorStatus
{
    public bool DatabaseFound { get; init; }
    public bool DatabaseReadable { get; init; }
    public bool SchemaSupported { get; init; }
    public string State { get; init; } = string.Empty;
}

internal sealed class MacOSExtractorScanResult
{
    public long Cursor { get; init; }
    public IReadOnlyList<MacOSExtractedNotification> Notifications { get; init; } = [];
    public int SkippedRecords { get; init; }
}

internal sealed class MacOSExtractedNotification
{
    public string NotificationId { get; init; } = string.Empty;
    public string PackageName { get; init; } = string.Empty;
    public string AppName { get; init; } = string.Empty;
    public string? Title { get; init; }
    public string? BodyPreview { get; init; }
    public string PostedAt { get; init; } = string.Empty;
    public bool IsDismissible { get; init; }
    public bool IsOpenable { get; init; }
}

internal sealed class MacOSExtractorException(string code, string message) : Exception(message)
{
    public string Code { get; } = code;
}
