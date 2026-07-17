namespace Rift.Daemon.Core.Interfaces;

public sealed class LocalMediaPlaybackActionResult
{
    public bool Success { get; init; }
    public string? FailureReason { get; init; }
    public string? Message { get; init; }
}

public interface ILocalMediaPlaybackActionHandler
{
    Task<LocalMediaPlaybackActionResult> HandleActionAsync(
        PendingIncomingMediaPlaybackAction request,
        CancellationToken cancellationToken);
}
