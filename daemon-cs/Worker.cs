namespace Rift.Daemon.Windows;

public class Worker(ILogger<Worker> logger, IpcListener ipcListener) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        logger.LogInformation("Rift Daemon (Windows) starting...");

        // Start IPC listener and await it so cancellation and faults are observed immediately
        var ipcTask = ipcListener.ListenAsync(stoppingToken);
        await ipcTask;
    }
}
