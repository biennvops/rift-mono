using System;
using System.Threading;
using System.Threading.Tasks;

namespace Rift.Daemon.Core.Interfaces;

public sealed class MessageReceivedEventArgs : EventArgs
{
    public string PeerDeviceId { get; }

    public ReadOnlyMemory<byte> Payload { get; }

    public MessageReceivedEventArgs(string peerDeviceId, ReadOnlyMemory<byte> payload)
    {
        PeerDeviceId = peerDeviceId ?? throw new ArgumentNullException(nameof(peerDeviceId));
        Payload = payload;
    }
}

public interface ITransport
{
    event EventHandler<MessageReceivedEventArgs> MessageReceived;

    Task StartListeningAsync(CancellationToken cancellationToken);

    Task ConnectToPeerAsync(string host, int port, CancellationToken cancellationToken);

    Task SendAsync(string peerDeviceId, ReadOnlyMemory<byte> frameBody, CancellationToken cancellationToken);

    Task DisconnectPeerAsync(string peerDeviceId, CancellationToken cancellationToken);
}
