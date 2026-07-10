namespace Rift.Daemon.Core.Networking;

public sealed class LocalNetworkAccessDeniedException : Exception
{
    public LocalNetworkAccessDeniedException(string message, Exception? inner = null)
        : base(message, inner)
    {
    }
}

