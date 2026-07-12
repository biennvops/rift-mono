using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Rift.Daemon.Core.Interfaces;
using Rift.Daemon.Core.Networking;
using System.Text;
using System.Text.Json;

namespace Rift.Daemon.Core;

public class Worker(
    ILogger<Worker> logger,
    IIpcListener ipcListener,
    IIdentityManager identityManager,
    IDiscoveryService discoveryService,
    ITransport transport,
    IProtocolMessageRouter protocolMessageRouter,
    IPresenceService presenceService,
    ITrustStore trustStore) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        logger.LogInformation("Rift Daemon starting...");
        identityManager.EnsureIdentityInitialized();
        await using var heartbeatManager = new SessionHeartbeatManager(transport, identityManager, presenceService);
        heartbeatManager.EnsureStarted(stoppingToken);

        var deviceId = identityManager.GetDeviceId();
        discoveryService.StartAdvertising(deviceId, "0.1-draft", "0.1-draft");
        
        if (!System.Linq.Enumerable.Any(trustStore.GetAllPeers()))
        {
            discoveryService.StartDiscovery();
        }

        transport.MessageReceived += OnTransportMessageReceived;
        transport.SessionStateChanged += OnSessionStateChanged;

        var ipcTask = ipcListener.ListenAsync(stoppingToken);
        var transportTask = transport.StartListeningAsync(stoppingToken);
        ObserveFault(ipcTask, "IPC listener");
        ObserveFault(transportTask, "transport listener");

        try
        {
            var completed = await Task.WhenAny(
                ipcTask,
                transportTask,
                Task.Delay(Timeout.Infinite, stoppingToken));

            if (completed == ipcTask)
            {
                await ipcTask;
            }
            else if (completed == transportTask)
            {
                await transportTask;
            }
        }
        finally
        {
            transport.MessageReceived -= OnTransportMessageReceived;
            transport.SessionStateChanged -= OnSessionStateChanged;
            discoveryService.StopAdvertising();
            discoveryService.StopDiscovery();
        }

        void ObserveFault(Task task, string component)
        {
            _ = task.ContinueWith(
                completedTask =>
                {
                    logger.LogError(completedTask.Exception, "{Component} task faulted.", component);
                },
                CancellationToken.None,
                TaskContinuationOptions.OnlyOnFaulted | TaskContinuationOptions.ExecuteSynchronously,
                TaskScheduler.Default);
        }

        void OnTransportMessageReceived(object? sender, MessageReceivedEventArgs args)
        {
            _ = Task.Run(async () =>
            {
                try
                {
                    heartbeatManager.ObserveAuthenticatedMessage(args.Session);
                    await protocolMessageRouter.HandleMessageAsync(args.Session, args.Payload, stoppingToken);
                }
                catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
                {
                    // Normal shutdown
                }
                catch (Exception ex)
                {
                    logger.LogWarning(ex, "Failed to route message from peer {PeerDeviceId}.", args.PeerDeviceId);
                }
            }, stoppingToken);
        }

        void OnSessionStateChanged(object? sender, SessionStateChangedEventArgs args)
        {
            if (args.IsOnline)
            {
                presenceService.UpdatePeerPresence(
                    args.PeerDeviceId,
                    "online",
                    DateTimeOffset.UtcNow.ToString("O"),
                    args.SelectedCapabilities);

                heartbeatManager.OnSessionStateChanged(args);

                if (!SessionHeartbeatManager.ShouldTrackPresence(args))
                {
                    return;
                }

                _ = Task.Run(async () =>
                {
                    try
                    {
                        await SendPresenceUpdateAsync(args.PeerDeviceId, args.SelectedCapabilities, stoppingToken);
                    }
                    catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
                    {
                        // Normal shutdown
                    }
                    catch (Exception ex)
                    {
                        logger.LogDebug(ex, "Failed to send presence update to peer {PeerDeviceId}.", args.PeerDeviceId);
                    }
                }, stoppingToken);
            }
            else
            {
                heartbeatManager.OnSessionStateChanged(args);
            }
        }

        async Task SendPresenceUpdateAsync(string peerDeviceId, IReadOnlyList<string> selectedCapabilities, CancellationToken cancellationToken)
        {
            var envelope = new
            {
                rift = "0.1-draft",
                type = "presence.update",
                messageId = Guid.NewGuid().ToString("D"),
                sourceDeviceId = deviceId,
                payload = new
                {
                    status = "online",
                    lastSeenAt = DateTimeOffset.UtcNow.ToString("O"),
                    capabilities = selectedCapabilities
                }
            };

            var payloadBytes = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(envelope));
            await transport.SendAsync(peerDeviceId, payloadBytes, cancellationToken);
        }
    }
}
