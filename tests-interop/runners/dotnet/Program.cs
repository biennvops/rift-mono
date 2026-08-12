using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Text.Json;
using Rift.Daemon.Core;
using Rift.Daemon.Core.Interfaces;
using StreamJsonRpc;

if (args.Length == 2 && string.Equals(args[0], "action", StringComparison.Ordinal))
{
    return await RunActionAsync(args[1]);
}

if (args.Length != 1)
{
    Console.Error.WriteLine("usage: Rift.NotificationInteropRunner <records.json>");
    return 2;
}

using var document = JsonDocument.Parse(await File.ReadAllTextAsync(args[0]));
if (document.RootElement.ValueKind != JsonValueKind.Array)
{
    Console.Error.WriteLine("records must be a JSON array");
    return 2;
}

var records = new List<Dictionary<string, object?>>();
foreach (var element in document.RootElement.EnumerateArray())
{
    var record = JsonSerializer.Deserialize<Dictionary<string, object?>>(element.GetRawText());
    if (record is null ||
        !record.TryGetValue("icon", out var rawIcon) ||
        rawIcon is not JsonElement { ValueKind: JsonValueKind.Object } iconElement)
    {
        Console.Error.WriteLine("each record must contain an icon object");
        return 2;
    }

    var icon = JsonSerializer.Deserialize<Dictionary<string, object?>>(iconElement.GetRawText());
    var normalized = NotificationIconNormalizer.Normalize(icon);
    if (normalized is null)
    {
        Console.Error.WriteLine("C# rejected a notification icon");
        return 1;
    }

    record["icon"] = normalized;
    records.Add(record);
}

Console.WriteLine(JsonSerializer.Serialize(records));
return 0;

static async Task<int> RunActionAsync(string mode)
{
    if (mode is not ("direct" or "ipc"))
    {
        Console.Error.WriteLine("action mode must be direct or ipc");
        return 2;
    }

    using var input = JsonDocument.Parse(await Console.In.ReadToEndAsync());
    var root = input.RootElement;
    var localDeviceId = root.GetProperty("localDeviceId").GetString() ?? string.Empty;
    var requestEnvelope = root.GetProperty("requestEnvelope");
    var requestPayload = requestEnvelope.GetProperty("payload");
    var transport = new RecordingTransport();
    var identity = new StubIdentityManager(localDeviceId);
    var ipc = mode == "ipc" ? new RecordingIpcNotificationService() : null;
    var direct = mode == "direct" ? new RecordingLocalNotificationActionHandler() : null;
    var service = new NotificationSyncService(
        transport,
        new PresenceService(),
        identity,
        new OperationService(),
        new NoOpSecurityEventLog(),
        ipc,
        localActionHandler: direct);

    await service.HandleNotificationPostedAsync(
        new NotificationSyncRecord
        {
            NotificationId = requestPayload.GetProperty("notificationId").GetString() ?? string.Empty,
            SourceDeviceId = localDeviceId,
            SourcePlatform = "interop",
            PackageName = "org.example.interop",
            AppName = "Interop Source",
            PostedAt = "2026-08-10T00:00:00Z",
            IsDismissible = true,
            IsOpenable = false
        },
        CancellationToken.None);
    await service.HandleNotificationActionRequestAsync(
        new NotificationActionRequestRecord
        {
            OperationId = requestPayload.GetProperty("operationId").GetString() ?? string.Empty,
            NotificationId = requestPayload.GetProperty("notificationId").GetString() ?? string.Empty,
            SourceDeviceId = requestPayload.GetProperty("sourceDeviceId").GetString() ?? string.Empty,
            RequestingDeviceId = requestPayload.GetProperty("requestingDeviceId").GetString() ?? string.Empty,
            Action = requestPayload.GetProperty("action").GetString() ?? string.Empty,
            RequestedAt = requestPayload.TryGetProperty("requestedAt", out var requestedAt)
                ? requestedAt.GetString()
                : null
        },
        CancellationToken.None);

    string? requestId = null;
    if (mode == "ipc")
    {
        var request = ipc!.Events.Single(evt => evt.Method == "rift.onNotificationActionRequest");
        requestId = JsonSerializer.SerializeToElement(request.Payload).GetProperty("requestId").GetString();
        await service.ReportHandledNotificationActionAsync(
            requestId!,
            success: true,
            failureReason: null,
            message: null,
            CancellationToken.None);
    }

    var resultEnvelope = transport.Envelopes.Single(
        envelope => envelope.GetProperty("type").GetString() == "notification.actionResult");
    Console.WriteLine(JsonSerializer.Serialize(new
    {
        mode,
        directExecutionCount = direct?.ExecutionCount ?? 0,
        requestId,
        actionResultEnvelope = resultEnvelope
    }));
    return 0;
}

file sealed class RecordingTransport : ITransport
{
    public event EventHandler<MessageReceivedEventArgs>? MessageReceived
    {
        add { }
        remove { }
    }

    public event EventHandler<SessionStateChangedEventArgs>? SessionStateChanged
    {
        add { }
        remove { }
    }

    public List<JsonElement> Envelopes { get; } = [];
    public Task StartListeningAsync(CancellationToken cancellationToken) => Task.CompletedTask;
    public Task ConnectToPeerAsync(string host, int port, CancellationToken cancellationToken) => Task.CompletedTask;
    public Task<string> ConnectToPeerWithIdentityAsync(string host, int port, CancellationToken cancellationToken, string? expectedDeviceId = null) =>
        Task.FromResult(expectedDeviceId ?? "rift-requester");
    public bool HasActiveSession(string peerDeviceId) => true;
    public bool HasProtectedSession(string peerDeviceId) => true;
    public void RefreshSessionAuthorization(string peerDeviceId) { }
    public PeerSessionEndpoint? GetPeerSessionEndpoint(string peerDeviceId) => null;
    public Task DisconnectPeerAsync(string peerDeviceId, CancellationToken cancellationToken) => Task.CompletedTask;

    public Task SendAsync(string peerDeviceId, ReadOnlyMemory<byte> frameBody, CancellationToken cancellationToken)
    {
        using var document = JsonDocument.Parse(frameBody);
        Envelopes.Add(document.RootElement.Clone());
        return Task.CompletedTask;
    }
}

file sealed class StubIdentityManager(string deviceId) : IIdentityManager
{
    public void EnsureIdentityInitialized() { }
    public string GetDeviceId() => deviceId;
    public byte[] GetEd25519PublicKey() => throw new NotSupportedException();
    public X509Certificate2 GetTlsCertificate() => throw new NotSupportedException();
    public byte[] SignEd25519(byte[] data) => throw new NotSupportedException();
    public string GetFingerprint() => throw new NotSupportedException();
    public string GetDisplayName() => "Interop Source";
    public bool VerifyEd25519(byte[] publicKey, byte[] data, byte[] signature) => throw new NotSupportedException();
}

file sealed class RecordingLocalNotificationActionHandler : ILocalNotificationActionHandler
{
    public int ExecutionCount { get; private set; }
    public bool CanPerform(NotificationSyncRecord notification, string action) => action == "dismiss";
    public Task<LocalNotificationActionResult> PerformAsync(
        NotificationSyncRecord notification,
        string action,
        CancellationToken cancellationToken)
    {
        ExecutionCount++;
        return Task.FromResult(new LocalNotificationActionResult { Success = true });
    }
}

file sealed class RecordingIpcNotificationService :
    IIpcNotificationService,
    IIpcNotificationActionExecutorService
{
    public bool HasClients => true;
    public bool HasExecutor => true;
    public List<(string Method, object Payload)> Events { get; } = [];
    public IDisposable RegisterClient(JsonRpc jsonRpc) => NoOpDisposable.Instance;
    public bool TryAcquire(JsonRpc jsonRpc) => true;
    public bool Release(JsonRpc jsonRpc) => true;
    public Task NotifyAsync(string method, object parameters, CancellationToken cancellationToken = default)
    {
        Events.Add((method, parameters));
        return Task.CompletedTask;
    }
    public Task<bool> NotifyExecutorAsync(string method, object parameters, CancellationToken cancellationToken = default)
    {
        Events.Add((method, parameters));
        return Task.FromResult(true);
    }

    private sealed class NoOpDisposable : IDisposable
    {
        public static readonly NoOpDisposable Instance = new();
        public void Dispose() { }
    }
}
