using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Rift.Daemon.Core.Interfaces;

namespace Rift.Daemon.Core;

public class Worker(ILogger<Worker> logger, IIpcListener ipcListener) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        logger.LogInformation("Rift Daemon starting...");

        var ipcTask = ipcListener.ListenAsync(stoppingToken);

        var completed = await Task.WhenAny(ipcTask, Task.Delay(Timeout.Infinite, stoppingToken));
        if (completed == ipcTask)
            await ipcTask;
    }
}
