using System;
using System.Threading;
using System.Threading.Tasks;

namespace Rift.Daemon.Windows.Core.Interfaces;

public interface ITransport
{
    /// <summary>
    /// Event triggered when a message is received from a peer.
    /// </summary>
    event EventHandler<(string DeviceId, byte[] Payload)>? MessageReceived;

    /// <summary>
    /// Starts listening for incoming mutual TLS 1.3 connections.
    /// </summary>
    Task StartListeningAsync(CancellationToken cancellationToken);

    /// <summary>
    /// Connects to a discovered peer via mutual TLS.
    /// </summary>
    Task ConnectToPeerAsync(string host, int port, CancellationToken cancellationToken);

    /// <summary>
    /// Dispatches a payload over the secure session to the specific peer.
    /// </summary>
    Task SendAsync(string deviceId, byte[] payload, CancellationToken cancellationToken);

    /// <summary>
    /// Closes the secure session with the specified peer.
    /// </summary>
    Task DisconnectPeerAsync(string deviceId, CancellationToken cancellationToken);
}
