namespace Rift.Daemon.Core.Interfaces;

public interface IPairingProtocolCoordinator
{
    Task NotifyLocalPairingStartedAsync(string deviceId, CancellationToken cancellationToken = default);

    Task<string> ConnectToEndpointForPairingAsync(string host, int port, CancellationToken cancellationToken = default);

    Task NotifyLocalPairingApprovedAsync(string deviceId, CancellationToken cancellationToken = default);

    Task NotifyLocalPairingRejectedAsync(string deviceId, CancellationToken cancellationToken = default);

    Task NotifyLocalTrustRemovedAsync(string deviceId, string reason, CancellationToken cancellationToken = default);

    Task HandleMessageAsync(string peerDeviceId, ReadOnlyMemory<byte> payload, CancellationToken cancellationToken);
}
