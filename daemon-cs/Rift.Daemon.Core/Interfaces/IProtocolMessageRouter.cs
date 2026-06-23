namespace Rift.Daemon.Core.Interfaces;

public interface IProtocolMessageRouter
{
    Task HandleMessageAsync(SessionPeerContext session, ReadOnlyMemory<byte> payload, CancellationToken cancellationToken);
}
