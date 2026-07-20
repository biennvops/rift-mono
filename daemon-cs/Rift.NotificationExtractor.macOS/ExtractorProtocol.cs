using System.Text.Json.Serialization;

namespace Rift.NotificationExtractor.macOS;

internal sealed class ExtractorRequest
{
    public string Id { get; init; } = string.Empty;
    public string Operation { get; init; } = string.Empty;
    public long? Cursor { get; init; }
}

internal sealed class ExtractorResponse
{
    public string Id { get; init; } = string.Empty;
    public bool Ok { get; init; }
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public object? Result { get; init; }
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public ExtractorError? Error { get; init; }
}

internal sealed class ExtractorError
{
    public string Code { get; init; } = string.Empty;
    public string Message { get; init; } = string.Empty;
}

internal sealed class ExtractorStatus
{
    public bool DatabaseFound { get; init; }
    public bool DatabaseReadable { get; init; }
    public bool SchemaSupported { get; init; }
    public string State { get; init; } = string.Empty;
}

internal sealed class NotificationScanResult
{
    public long Cursor { get; init; }
    public IReadOnlyList<ExtractedNotification> Notifications { get; init; } = [];
    public int SkippedRecords { get; init; }
}

internal sealed class ExtractedNotification
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
