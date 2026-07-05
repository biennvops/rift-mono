using System;
using System.Threading;
using System.Threading.Tasks;

namespace Rift.Daemon.Core.Interfaces;

/// <summary>
/// Carries one decoded frame received from a peer session.
/// The <see cref="Payload"/> bytes are the raw UTF-8 JSON object exactly as read from the wire,
/// with the 4-byte big-endian length prefix already stripped. Consumers MUST NOT
/// buffer or forward frames that exceeded the applicable size limit
/// (64 KiB pre-authentication, 32 MiB post-authentication — spec §1).
/// </summary>
public sealed class MessageReceivedEventArgs : EventArgs
{
    /// <summary>Source device ID of the authenticated session, as derived from the TLS-bound Ed25519 identity.</summary>
    public string PeerDeviceId { get; }

    /// <summary>
    /// Raw UTF-8-encoded JSON object (the frame body, length prefix stripped).
    /// Callers MUST treat this buffer as read-only; implementations are not
    /// required to copy it.
    /// </summary>
    public ReadOnlyMemory<byte> Payload { get; }

    public SessionPeerContext Session { get; }

    public MessageReceivedEventArgs(string peerDeviceId, ReadOnlyMemory<byte> payload, SessionPeerContext session)
    {
        PeerDeviceId = peerDeviceId ?? throw new ArgumentNullException(nameof(peerDeviceId));
        Payload = payload;
        Session = session ?? throw new ArgumentNullException(nameof(session));
    }
}

public sealed class SessionPeerContext
{
    public string PeerDeviceId { get; }

    public IReadOnlyList<string> SelectedCapabilities { get; }

    public bool AllowsProtectedTraffic { get; }

    public SessionPeerContext(string peerDeviceId, IReadOnlyList<string> selectedCapabilities, bool allowsProtectedTraffic)
    {
        PeerDeviceId = peerDeviceId ?? throw new ArgumentNullException(nameof(peerDeviceId));
        SelectedCapabilities = selectedCapabilities ?? throw new ArgumentNullException(nameof(selectedCapabilities));
        AllowsProtectedTraffic = allowsProtectedTraffic;
    }

    public bool HasCapability(string capabilityName)
    {
        ArgumentNullException.ThrowIfNull(capabilityName);
        return SelectedCapabilities.Contains(capabilityName, StringComparer.Ordinal);
    }
}

public sealed class SessionStateChangedEventArgs : EventArgs
{
    public string PeerDeviceId { get; }

    public bool IsOnline { get; }

    public IReadOnlyList<string> SelectedCapabilities { get; }

    public bool AllowsProtectedTraffic { get; }

    public SessionStateChangedEventArgs(string peerDeviceId, bool isOnline, IReadOnlyList<string> selectedCapabilities, bool allowsProtectedTraffic)
    {
        PeerDeviceId = peerDeviceId ?? throw new ArgumentNullException(nameof(peerDeviceId));
        IsOnline = isOnline;
        SelectedCapabilities = selectedCapabilities ?? throw new ArgumentNullException(nameof(selectedCapabilities));
        AllowsProtectedTraffic = allowsProtectedTraffic;
    }
}

public sealed class PeerSessionEndpoint
{
    public string Address { get; }

    public int Port { get; }

    public PeerSessionEndpoint(string address, int port)
    {
        Address = address ?? throw new ArgumentNullException(nameof(address));
        Port = port;
    }
}

/// <summary>
/// Peer-transport abstraction for the Rift daemon.
///
/// <para>
/// Wire framing (spec §1): every frame is a 4-byte unsigned big-endian length
/// followed by a UTF-8 JSON object. Pre-authentication frames are capped at 64 KiB;
/// post-authentication frames are capped at 32 MiB. Implementations MUST enforce
/// these limits before buffering the frame body and MUST close the connection on
/// violation.
/// </para>
///
/// <para>
/// Security invariant: every authenticated session is bound to exactly one
/// Ed25519 device ID verified during the TLS+PoP handshake (spec §5.2–5.3).
/// The device ID passed to <see cref="SendAsync"/> and surfaced through
/// <see cref="MessageReceived"/> is always that authenticated identity —
/// never a value taken from an unauthenticated discovery record.
/// </para>
/// </summary>
public interface ITransport
{
    // -------------------------------------------------------------------------
    // Inbound
    // -------------------------------------------------------------------------

    /// <summary>
    /// Raised on the implementation's I/O thread whenever a complete, size-validated
    /// frame is decoded from a peer session. Subscribers MUST NOT perform
    /// long-running work inside the handler; dispatch to a channel or queue instead.
    /// </summary>
    event EventHandler<MessageReceivedEventArgs> MessageReceived;

    /// <summary>
    /// Raised whenever an authenticated peer session becomes available or is torn down.
    /// </summary>
    event EventHandler<SessionStateChangedEventArgs> SessionStateChanged;

    /// <summary>
    /// Starts accepting incoming mutual TLS 1.3 connections (spec §5.1).
    /// The implementation raises <see cref="MessageReceived"/> for every valid
    /// inbound frame on every accepted session.
    /// </summary>
    /// <param name="cancellationToken">Signals the listener to stop.</param>
    Task StartListeningAsync(CancellationToken cancellationToken);

    // -------------------------------------------------------------------------
    // Outbound
    // -------------------------------------------------------------------------

    /// <summary>
    /// Initiates a mutual TLS connection to the specified peer endpoint (spec §5.1).
    /// After the TLS handshake and Ed25519 Proof-of-Possession exchange (spec §5.3)
    /// succeed, inbound frames from the new session are delivered via
    /// <see cref="MessageReceived"/>.
    /// </summary>
    /// <param name="host">Resolved hostname or IP address of the peer.</param>
    /// <param name="port">TCP port advertised in the peer's mDNS SRV record.</param>
    /// <param name="cancellationToken">Cancels the connection attempt.</param>
    Task ConnectToPeerAsync(string host, int port, CancellationToken cancellationToken);

    /// <summary>
    /// Initiates a mutual TLS connection to the specified peer endpoint and
    /// returns the authenticated peer device ID derived from the TLS-bound
    /// Ed25519 identity after session bootstrap completes.
    /// </summary>
    Task<string> ConnectToPeerWithIdentityAsync(string host, int port, CancellationToken cancellationToken);

    /// <summary>
    /// Returns <see langword="true"/> when an authenticated session already exists
    /// for the specified peer device ID and can be reused for protocol traffic.
    /// </summary>
    bool HasActiveSession(string peerDeviceId);

    /// <summary>
    /// Returns the current authenticated session's remote socket endpoint for the peer,
    /// if one is presently registered.
    /// </summary>
    PeerSessionEndpoint? GetPeerSessionEndpoint(string peerDeviceId);

    /// <summary>
    /// Writes a single framed message to the authenticated session identified by
    /// <paramref name="peerDeviceId"/>.
    ///
    /// <para>
    /// <paramref name="frameBody"/> MUST be the raw UTF-8-encoded JSON object
    /// (the frame body only — callers MUST NOT prepend the 4-byte length prefix;
    /// the implementation prepends it). Use <see cref="RiftFrame.Encode"/> to
    /// serialise a <c>RiftMessage</c> envelope into the correct form.
    /// </para>
    ///
    /// <para>
    /// The implementation MUST reject a frame body that exceeds the applicable
    /// size limit (64 KiB pre-auth / 32 MiB post-auth) with
    /// <see cref="InvalidOperationException"/> before writing any bytes to the
    /// wire. This mirrors the receiver-side enforcement required by spec §1.
    /// </para>
    /// </summary>
    /// <param name="peerDeviceId">
    /// The authenticated Ed25519-derived device ID of the target session
    /// (matches <c>^rift-[a-z2-7]{32}$</c>).
    /// </param>
    /// <param name="frameBody">UTF-8 JSON object bytes (no length prefix).</param>
    /// <param name="cancellationToken">Cancels the write.</param>
    /// <exception cref="InvalidOperationException">
    /// No open session exists for <paramref name="peerDeviceId"/>, or the frame
    /// body exceeds the applicable size limit.
    /// </exception>
    Task SendAsync(string peerDeviceId, ReadOnlyMemory<byte> frameBody, CancellationToken cancellationToken);

    // -------------------------------------------------------------------------
    // Session teardown
    // -------------------------------------------------------------------------

    /// <summary>
    /// Gracefully closes the authenticated session with the specified peer and
    /// releases all associated resources.
    ///
    /// <para>
    /// Implementations SHOULD perform a TLS close-notify before closing the TCP
    /// connection. If the peer does not respond within a reasonable timeout,
    /// the underlying socket MUST be forcibly closed.
    /// </para>
    ///
    /// <para>
    /// Callers MUST invoke this method when a trust-state transition requires
    /// session termination (e.g. block, revoke — spec §8), or when the daemon is
    /// shutting down.
    /// </para>
    /// </summary>
    /// <param name="peerDeviceId">Device ID of the session to close.</param>
    /// <param name="cancellationToken">Cancels the close-notify wait.</param>
    /// <returns>
    /// A completed <see cref="Task"/> when the session is fully closed, or a no-op
    /// task if no open session exists for the given device ID.
    /// </returns>
    Task DisconnectPeerAsync(string peerDeviceId, CancellationToken cancellationToken);
}
