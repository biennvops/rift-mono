namespace Rift.Daemon.Core.Interfaces;

public interface IProtocolMessageRouter
{
    Task HandleMessageAsync(string peerDeviceId, ReadOnlyMemory<byte> payload, CancellationToken cancellationToken);
}
