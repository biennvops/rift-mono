using System.Threading.Tasks;

namespace Rift.Daemon.Windows.Core.Interfaces;

public enum SecurityEventType
{
    AuthenticationSuccess,
    AuthenticationFailure,
    PairingStarted,
    StateTransition,
    Disconnect
}

public interface ISecurityEventLog
{
    /// <summary>
    /// Appends a new security event to the append-only log.
    /// </summary>
    Task LogEventAsync(SecurityEventType eventType, string peerDeviceId, string description);
}
