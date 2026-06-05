namespace Rift.Daemon.Windows;

public class Worker(ILogger<Worker> logger, IpcListener ipcListener) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        logger.LogInformation("Rift Daemon (Windows) starting...");

        // Start IPC listener in the background
        var ipcTask = ipcListener.ListenAsync(stoppingToken);

        while (!stoppingToken.IsCancellationRequested)
        {
            await Task.Delay(10000, stoppingToken);
        }

        await ipcTask;
    }
}
