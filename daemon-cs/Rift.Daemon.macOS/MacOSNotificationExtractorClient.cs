using System.Runtime.InteropServices;
using System.Text;
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
    private const int MaximumRequestBytes = 64 * 1024;
    private const int MaximumResponseBytes = 1024 * 1024;
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);

    private readonly Func<byte[], TimeSpan, CancellationToken, Task<byte[]>> _sendAsync;
    private readonly TimeSpan _requestTimeout;

    public MacOSNotificationExtractorClient()
        : this(SendNativeAsync, TimeSpan.FromSeconds(10))
    {
    }

    internal MacOSNotificationExtractorClient(
        Func<byte[], TimeSpan, CancellationToken, Task<byte[]>> sendAsync,
        TimeSpan? requestTimeout = null)
    {
        _sendAsync = sendAsync;
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
        var requestId = Guid.NewGuid().ToString("D");
        var request = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(new
        {
            id = requestId,
            operation,
            cursor
        }, JsonOptions));
        if (request.Length > MaximumRequestBytes)
        {
            throw new MacOSExtractorException("requestTooLarge", "Rift Notification Extractor request exceeded 64 KiB.");
        }

        byte[] responseBytes;
        try
        {
            responseBytes = await _sendAsync(request, _requestTimeout, cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            throw new MacOSExtractorException("extractorTimeout", "Rift Notification Extractor did not respond in time.");
        }
        if (responseBytes.Length > MaximumResponseBytes)
        {
            throw new MacOSExtractorException("responseTooLarge", "Rift Notification Extractor response exceeded 1 MiB.");
        }

        ExtractorResponse? response;
        try
        {
            response = JsonSerializer.Deserialize<ExtractorResponse>(responseBytes, JsonOptions);
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

    private static async Task<byte[]> SendNativeAsync(
        byte[] request,
        TimeSpan timeout,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var timeoutMilliseconds = checked((int)Math.Clamp(timeout.TotalMilliseconds, 1, int.MaxValue));
        return await Task.Run(() =>
        {
            cancellationToken.ThrowIfCancellationRequested();
            var status = NativeMethods.Send(
                request,
                request.Length,
                timeoutMilliseconds,
                out var responsePointer,
                out var responseLength);
            try
            {
                if (status != 0)
                {
                    throw CreateNativeException(status);
                }
                if (responsePointer == IntPtr.Zero || responseLength <= 0 || responseLength > MaximumResponseBytes)
                {
                    throw new MacOSExtractorException("invalidResponse", "Rift Notification Extractor returned an invalid native response.");
                }

                var response = new byte[responseLength];
                Marshal.Copy(responsePointer, response, 0, responseLength);
                return response;
            }
            finally
            {
                if (responsePointer != IntPtr.Zero)
                {
                    NativeMethods.Free(responsePointer);
                }
            }
        }, CancellationToken.None).WaitAsync(cancellationToken).ConfigureAwait(false);
    }

    private static MacOSExtractorException CreateNativeException(int status) => status switch
    {
        1 => new MacOSExtractorException("invalidRequest", "The native extractor request was invalid."),
        2 => new MacOSExtractorException("authenticationFailed", "The authenticated extractor connection failed."),
        3 => new MacOSExtractorException("extractorTimeout", "Rift Notification Extractor did not respond in time."),
        4 => new MacOSExtractorException("responseTooLarge", "Rift Notification Extractor response exceeded 1 MiB."),
        5 => new MacOSExtractorException("allocationFailed", "The native extractor client could not allocate its response."),
        _ => new MacOSExtractorException("xpcFailed", "The native extractor request failed.")
    };

    private static class NativeMethods
    {
        [DllImport("librift-notification-xpc-client.dylib", EntryPoint = "rift_notification_xpc_send")]
        internal static extern int Send(
            byte[] requestBytes,
            int requestLength,
            int timeoutMilliseconds,
            out IntPtr responseBytes,
            out int responseLength);

        [DllImport("librift-notification-xpc-client.dylib", EntryPoint = "rift_notification_xpc_free")]
        internal static extern void Free(IntPtr pointer);
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
