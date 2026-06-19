namespace Rift.Daemon.Core.Interfaces;

public interface IPairingProtocolCoordinator
{
    void NotifyLocalPairingStarted(string deviceId);

    void NotifyLocalPairingApproved(string deviceId);

    void NotifyLocalPairingRejected(string deviceId);

    Task HandleMessageAsync(string peerDeviceId, ReadOnlyMemory<byte> payload, CancellationToken cancellationToken);
}
