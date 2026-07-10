using System.Net.Sockets;

namespace Rift.Daemon.Core.Networking;

internal static class LocalNetworkPolicy
{
    internal static bool IsAccessDenied(Exception ex)
    {
        // Best-effort mapping across macOS/.NET networking stacks:
        // Local Network denial often surfaces as EPERM/EACCES or AccessDenied.
        for (Exception? cur = ex; cur is not null; cur = cur.InnerException)
        {
            if (cur is SocketException se)
            {
                if (se.SocketErrorCode is SocketError.AccessDenied)
                {
                    return true;
                }
            }

            // Some APIs wrap errno in IOException/HResult. Keep this conservative:
            // treat explicit "permission" wording as denial rather than guessing other failures.
            var msg = cur.Message ?? string.Empty;
            if (msg.Contains("Operation not permitted", StringComparison.OrdinalIgnoreCase) ||
                msg.Contains("Permission denied", StringComparison.OrdinalIgnoreCase) ||
                msg.Contains("not permitted", StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }
        }

        return false;
    }
}

