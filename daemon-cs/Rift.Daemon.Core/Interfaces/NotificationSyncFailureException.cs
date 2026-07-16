namespace Rift.Daemon.Core.Interfaces;

public sealed class NotificationSyncFailureException(string message, int errorCode) : Exception(message)
{
    public int ErrorCode { get; } = errorCode;
}
