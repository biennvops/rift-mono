using System;
using System.Collections.Generic;
using System.Threading.Tasks;

namespace Rift.Daemon.Core.Interfaces;

public enum SecurityEventSeverity
{
    Info,
    Warning,
    Error,
    Critical
}

public enum SecurityEventOutcome
{
    Success,
    Failure,
    Denied
}

public static class SecurityEventTypes
{
    public const string PairingAttempted = "pairing.attempted";
    public const string PairingCompleted = "pairing.completed";
    public const string PairingRejected = "pairing.rejected";
    public const string TrustTransitioned = "trust.transitioned";
    public const string TrustRevoked = "trust.revoked";
    public const string AuthFailed = "auth.failed";
    public const string AuthIdentityProofFailed = "auth.identity_proof_failed";
    public const string ConnectionEstablished = "connection.established";
    public const string ConnectionRejected = "connection.rejected";
    public const string ConnectionLost = "connection.lost";
    public const string CertificateRotated = "certificate.rotated";
    public const string CapabilityNegotiated = "capability.negotiated";
    public const string OperationTransitioned = "operation.transitioned";
    public const string ClipboardOffered = "clipboard.offered";
    public const string ClipboardFetched = "clipboard.fetched";
    public const string ClipboardExpired = "clipboard.expired";
    public const string ClipboardOfferReplay = "clipboard.offer_replay";
    public const string MessageMalformed = "message.malformed";
    public const string CertificateMalformed = "certificate.malformed";
    public const string PolicyDenied = "policy.denied";
}

public class SecurityEventRecord
{
    public string EventId { get; init; } = Guid.NewGuid().ToString("D").ToLowerInvariant();
    public string EventType { get; init; } = string.Empty;
    public SecurityEventSeverity Severity { get; init; }
    public string LocalDeviceId { get; init; } = string.Empty;
    public string? PeerDeviceId { get; init; }
    public string? OperationId { get; init; }
    public DateTimeOffset Timestamp { get; init; } = DateTimeOffset.UtcNow;
    public SecurityEventOutcome Outcome { get; init; }
    public string? FailureReason { get; init; }
    public IDictionary<string, object>? Details { get; init; }
}

public sealed class SecurityEventQuery
{
    public IReadOnlyList<string>? EventTypes { get; init; }
    public IReadOnlyList<string>? Severities { get; init; }
    public string? PeerDeviceId { get; init; }
    public DateTimeOffset? Since { get; init; }
    public int Limit { get; init; } = 100;
    public int Offset { get; init; }
}

public interface ISecurityEventLog
{
    /// <summary>
    /// Appends a new security event to the append-only log.
    /// </summary>
    Task LogEventAsync(SecurityEventRecord securityEvent);

    /// <summary>
    /// Queries security events using optional filters.
    /// </summary>
    Task<IReadOnlyList<SecurityEventRecord>> QueryEventsAsync(SecurityEventQuery query);
}
