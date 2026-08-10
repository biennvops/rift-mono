namespace Rift.Daemon.Core.Interfaces;

public sealed class MediaPlaybackRecord
{
    public string PlaybackId { get; init; } = string.Empty;
    public string SourceDeviceId { get; init; } = string.Empty;
    public string? SourcePlatform { get; init; }
    public string AppId { get; init; } = string.Empty;
    public string AppName { get; init; } = string.Empty;
    public string? Title { get; init; }
    public string? Artist { get; init; }
    public string? Album { get; init; }
    public IReadOnlyDictionary<string, object?>? Artwork { get; init; }
    public string PlaybackState { get; init; } = string.Empty;
    public long PositionMs { get; init; }
    public long? DurationMs { get; init; }
    public bool CanPlay { get; init; }
    public bool CanPause { get; init; }
    public bool CanSkipNext { get; init; }
    public bool CanSkipPrevious { get; init; }
    public bool CanSeek { get; init; }
    public string UpdatedAt { get; init; } = string.Empty;
    public bool IsRemoved { get; init; }
    public string? RemovedAt { get; init; }
}

public sealed class ListMediaPlaybackResult
{
    public IReadOnlyList<MediaPlaybackRecord> Playbacks { get; init; } = [];
}

public sealed class PerformMediaPlaybackActionResult
{
    public string OperationId { get; init; } = string.Empty;
    public string PlaybackId { get; init; } = string.Empty;
    public string Action { get; init; } = string.Empty;
    public string State { get; init; } = string.Empty;
}

public sealed class NotifyLocalMediaPlaybackEventResult
{
    public string PlaybackId { get; init; } = string.Empty;
    public IReadOnlyList<string> BroadcastTo { get; init; } = [];
}

public sealed class MediaPlaybackRemovedRecord
{
    public string PlaybackId { get; init; } = string.Empty;
    public string SourceDeviceId { get; init; } = string.Empty;
    public string? RemovedAt { get; init; }
}

public sealed class MediaPlaybackActionResultRecord
{
    public string PlaybackId { get; init; } = string.Empty;
    public string SourceDeviceId { get; init; } = string.Empty;
    public string RequestingDeviceId { get; init; } = string.Empty;
    public string Action { get; init; } = string.Empty;
    public bool Success { get; init; }
    public string? FailureReason { get; init; }
    public string? Message { get; init; }
}

public sealed class MediaPlaybackActionRequestRecord
{
    public string PlaybackId { get; init; } = string.Empty;
    public string SourceDeviceId { get; init; } = string.Empty;
    public string RequestingDeviceId { get; init; } = string.Empty;
    public string Action { get; init; } = string.Empty;
    public long? PositionMs { get; init; }
    public string? RequestedAt { get; init; }
}

public sealed class PendingIncomingMediaPlaybackAction
{
    public string RequestId { get; init; } = string.Empty;
    public string PlaybackId { get; init; } = string.Empty;
    public string SourceDeviceId { get; init; } = string.Empty;
    public string RequestingDeviceId { get; init; } = string.Empty;
    public string Action { get; init; } = string.Empty;
    public long? PositionMs { get; init; }
}

public sealed class ReportHandledMediaPlaybackActionResult
{
    public string RequestId { get; init; } = string.Empty;
    public string PlaybackId { get; init; } = string.Empty;
    public string Action { get; init; } = string.Empty;
    public bool Success { get; init; }
}

public interface IMediaPlaybackSyncService
{
    Task<NotifyLocalMediaPlaybackEventResult> HandleLocalPlaybackEventAsync(
        string eventType,
        MediaPlaybackRecord playback,
        string? removedAt,
        CancellationToken cancellationToken);

    Task PublishLocalPlaybackToPeerAsync(
        string peerDeviceId,
        MediaPlaybackRecord playback,
        CancellationToken cancellationToken);

    Task SendPeerErrorAsync(
        string peerDeviceId,
        string failureReason,
        string? refMessageId,
        string message,
        CancellationToken cancellationToken);

    Task<ListMediaPlaybackResult> ListMediaPlaybackAsync(CancellationToken cancellationToken);

    Task<MediaPlaybackRecord> GetMediaPlaybackAsync(
        string sourceDeviceId,
        string playbackId,
        CancellationToken cancellationToken);

    Task<PerformMediaPlaybackActionResult> PerformMediaPlaybackActionAsync(
        string sourceDeviceId,
        string playbackId,
        string action,
        long? positionMs,
        CancellationToken cancellationToken);

    Task HandleMediaPlaybackPostedAsync(MediaPlaybackRecord playback, CancellationToken cancellationToken);

    Task HandleMediaPlaybackUpdatedAsync(MediaPlaybackRecord playback, CancellationToken cancellationToken);

    Task HandleMediaPlaybackRemovedAsync(MediaPlaybackRemovedRecord playback, CancellationToken cancellationToken);

    Task HandleMediaPlaybackActionResultAsync(MediaPlaybackActionResultRecord result, CancellationToken cancellationToken);

    Task HandleMediaPlaybackActionRequestAsync(MediaPlaybackActionRequestRecord request, CancellationToken cancellationToken);

    Task<ReportHandledMediaPlaybackActionResult> ReportHandledMediaPlaybackActionAsync(
        string requestId,
        bool success,
        string? failureReason,
        string? message,
        CancellationToken cancellationToken);
}
