using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Rift.Daemon.Core.Interfaces;

namespace Rift.Daemon.Core;

public class Worker(
    ILogger<Worker> logger,
    IIpcListener ipcListener,
    IDiscoveryService discoveryService,
    ITransport transport,
    IIdentityManager identityManager) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        logger.LogInformation("Rift Daemon starting...");

        // Initialize identity
        identityManager.EnsureIdentityInitialized();
        string deviceId = identityManager.GetDeviceId();
        logger.LogInformation("Device ID: {DeviceId}", deviceId);
        logger.LogInformation("Pairing Fingerprint: {Fingerprint}", identityManager.GetFingerprint());

        // Start TLS Transport
        var transportTask = transport.StartListeningAsync(stoppingToken);

        // Start Discovery (Advertising and Browsing)
        if (transport is Networking.TlsTransport tlsTransport)
        {
            // Update discovery with the actual listening port
            // We might need to wait a bit or ensure the listener is bound
            await Task.Yield(); 
            if (discoveryService is Networking.DiscoveryService ds)
            {
                ds.Port = tlsTransport.ListeningPort;
            }
        }
        
        discoveryService.StartAdvertising(deviceId, "0.1-draft", "0.1-draft");
        discoveryService.StartDiscovery();

        var ipcTask = ipcListener.ListenAsync(stoppingToken);

        await Task.WhenAll(ipcTask, transportTask);
    }
}
