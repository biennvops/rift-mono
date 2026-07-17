namespace Rift.Daemon.Core.Interfaces;

public sealed class MediaPlaybackSyncFailureException(string message, int errorCode) : Exception(message)
{
    public int ErrorCode { get; } = errorCode;
}
