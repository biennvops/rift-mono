namespace Rift.Daemon.Core.Interfaces;

public interface IIpcListener
{
    Task ListenAsync(CancellationToken stoppingToken);
}
