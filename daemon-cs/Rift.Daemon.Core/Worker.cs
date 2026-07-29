using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Rift.Daemon.Core.Interfaces;
using Rift.Daemon.Core.Networking;
using System.Collections.Concurrent;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Threading.Channels;

namespace Rift.Daemon.Core;

public class Worker(
    ILogger<Worker> logger,
    IIpcListener ipcListener,
    IIdentityManager identityManager,
    ITrustStore trustStore,
    IDiscoveryService discoveryService,
    ITransport transport,
    IProtocolMessageRouter protocolMessageRouter,
    IPresenceService presenceService) : BackgroundService
{
    private static readonly TimeSpan TrustedReconnectPollInterval = TimeSpan.FromSeconds(1);
    private static readonly TimeSpan TrustedReconnectPassiveDelay = TimeSpan.FromSeconds(2);
    private static readonly TimeSpan TrustedReconnectRetryDelay = TimeSpan.FromSeconds(3);
    private static readonly TimeSpan TrustedReconnectEndpointTimeout = TimeSpan.FromSeconds(3);

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        logger.LogInformation("Rift Daemon starting...");
        identityManager.EnsureIdentityInitialized();
        await using var heartbeatManager = new SessionHeartbeatManager(transport, identityManager, presenceService);
        heartbeatManager.EnsureStarted(stoppingToken);

        var deviceId = identityManager.GetDeviceId();
        discoveryService.StartAdvertising(deviceId, "0.1-draft", "0.1-draft");
        if (ShouldAutoStartDiscovery(trustStore))
        {
            discoveryService.StartDiscovery();
        }
        var peerMessageQueues = new Dictionary<string, Channel<MessageReceivedEventArgs>>(StringComparer.Ordinal);
        var peerMessageWorkers = new Dictionary<string, Task>(StringComparer.Ordinal);
        var peerMessageQueuesGate = new object();
        var trustedReconnectLoops = new Dictionary<string, Task>(StringComparer.Ordinal);
        var trustedReconnectLoopsGate = new object();
        using var trustedReconnectCts = CancellationTokenSource.CreateLinkedTokenSource(stoppingToken);
        var trustedReconnectToken = trustedReconnectCts.Token;
        transport.MessageReceived += OnTransportMessageReceived;
        transport.SessionStateChanged += OnSessionStateChanged;

        var ipcTask = ipcListener.ListenAsync(stoppingToken);
        var transportTask = transport.StartListeningAsync(stoppingToken);
        ObserveFault(ipcTask, "IPC listener");
        ObserveFault(transportTask, "transport listener");

        foreach (var peer in trustStore.GetAllPeers().Where(peer => peer.State == TrustState.Trusted))
        {
            EnsureTrustedReconnectLoop(peer.DeviceId);
        }

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
            Channel<MessageReceivedEventArgs>[] messageQueues;
            Task[] messageWorkers;
            lock (peerMessageQueuesGate)
            {
                messageQueues = peerMessageQueues.Values.ToArray();
                messageWorkers = peerMessageWorkers.Values.ToArray();
            }
            foreach (var queue in messageQueues)
            {
                queue.Writer.TryComplete();
            }
            try
            {
                await Task.WhenAll(messageWorkers);
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
            {
                // Normal shutdown
            }
            discoveryService.StopAdvertising();
            discoveryService.StopDiscovery();
            trustedReconnectCts.Cancel();
            Task[] reconnectLoopTasks;
            lock (trustedReconnectLoopsGate)
            {
                reconnectLoopTasks = trustedReconnectLoops.Values.ToArray();
            }
            try
            {
                await Task.WhenAll(reconnectLoopTasks);
            }
            catch (OperationCanceledException) when (trustedReconnectToken.IsCancellationRequested)
            {
                // Normal shutdown
            }
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
            Channel<MessageReceivedEventArgs> queue;
            lock (peerMessageQueuesGate)
            {
                if (peerMessageQueues.TryGetValue(args.PeerDeviceId, out var existingQueue))
                {
                    queue = existingQueue;
                }
                else
                {
                    queue = Channel.CreateUnbounded<MessageReceivedEventArgs>(
                        new UnboundedChannelOptions
                        {
                            SingleReader = true,
                            SingleWriter = false,
                            AllowSynchronousContinuations = false
                        });
                    peerMessageQueues.Add(args.PeerDeviceId, queue);
                    peerMessageWorkers.Add(
                        args.PeerDeviceId,
                        Task.Run(() => ProcessPeerMessagesAsync(args.PeerDeviceId, queue), stoppingToken));
                }
            }
            queue.Writer.TryWrite(args);
        }

        async Task ProcessPeerMessagesAsync(
            string peerDeviceId,
            Channel<MessageReceivedEventArgs> queue)
        {
            try
            {
                await foreach (var args in queue.Reader.ReadAllAsync(stoppingToken))
                {
                    try
                    {
                        var messageType = GetMessageType(args.Payload);
                        logger.LogInformation(
                            "Routing protocol message {MessageType} from peer {PeerDeviceId}.",
                            messageType,
                            peerDeviceId);
                        heartbeatManager.ObserveAuthenticatedMessage(args.Session);
                        await protocolMessageRouter.HandleMessageAsync(args.Session, args.Payload, stoppingToken);
                        logger.LogInformation(
                            "Routed protocol message {MessageType} from peer {PeerDeviceId}.",
                            messageType,
                            peerDeviceId);
                    }
                    catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
                    {
                        return;
                    }
                    catch (Exception ex)
                    {
                        logger.LogWarning(ex, "Failed to route message from peer {PeerDeviceId}.", peerDeviceId);
                    }
                }
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
            {
                // Normal shutdown
            }
        }

        static string GetMessageType(ReadOnlyMemory<byte> payload)
        {
            try
            {
                using var document = JsonDocument.Parse(payload);
                return document.RootElement.TryGetProperty("type", out var typeElement)
                    ? typeElement.GetString() ?? "unknown"
                    : "unknown";
            }
            catch (JsonException)
            {
                return "malformed";
            }
        }

        void OnSessionStateChanged(object? sender, SessionStateChangedEventArgs args)
        {
            EnsureTrustedReconnectLoop(args.PeerDeviceId);
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

        void EnsureTrustedReconnectLoop(string peerDeviceId)
        {
            var peer = trustStore.GetAllPeers().FirstOrDefault(candidate =>
                string.Equals(candidate.DeviceId, peerDeviceId, StringComparison.Ordinal));
            if (peer?.State != TrustState.Trusted)
            {
                return;
            }

            lock (trustedReconnectLoopsGate)
            {
                if (trustedReconnectLoops.TryGetValue(peerDeviceId, out var existingLoop) &&
                    !existingLoop.IsCompleted)
                {
                    return;
                }

                trustedReconnectLoops[peerDeviceId] =
                    Task.Run(() => RunTrustedReconnectLoopAsync(peerDeviceId), CancellationToken.None);
            }
        }

        async Task RunTrustedReconnectLoopAsync(string peerDeviceId)
        {
            var passiveDelayApplied = false;
            var preferredInitiator = string.CompareOrdinal(deviceId, peerDeviceId) < 0;

            while (!trustedReconnectToken.IsCancellationRequested)
            {
                var peer = trustStore.GetAllPeers().FirstOrDefault(candidate =>
                    string.Equals(candidate.DeviceId, peerDeviceId, StringComparison.Ordinal));
                if (peer?.State != TrustState.Trusted)
                {
                    return;
                }

                if (transport.HasActiveSession(peerDeviceId))
                {
                    passiveDelayApplied = false;
                    await Task.Delay(TrustedReconnectPollInterval, trustedReconnectToken);
                    continue;
                }

                if (!preferredInitiator && !passiveDelayApplied)
                {
                    passiveDelayApplied = true;
                    await Task.Delay(TrustedReconnectPassiveDelay, trustedReconnectToken);
                    if (transport.HasActiveSession(peerDeviceId))
                    {
                        continue;
                    }
                }

                foreach (var endpoint in peer.TrustedEndpoints.OrderByDescending(endpoint => endpoint.LastSuccessAt))
                {
                    if (transport.HasActiveSession(peerDeviceId))
                    {
                        break;
                    }

                    using var timeoutCts = CancellationTokenSource.CreateLinkedTokenSource(trustedReconnectToken);
                    timeoutCts.CancelAfter(TrustedReconnectEndpointTimeout);
                    try
                    {
                        var connectedDeviceId = await transport.ConnectToPeerWithIdentityAsync(
                            endpoint.Address,
                            endpoint.Port,
                            timeoutCts.Token);
                        if (!string.Equals(connectedDeviceId, peerDeviceId, StringComparison.Ordinal))
                        {
                            logger.LogWarning(
                                "Trusted reconnect endpoint {Address}:{Port} authenticated unexpected peer {ConnectedDeviceId} instead of {ExpectedDeviceId}.",
                                endpoint.Address,
                                endpoint.Port,
                                connectedDeviceId,
                                peerDeviceId);
                            await transport.DisconnectPeerAsync(connectedDeviceId, trustedReconnectToken);
                            continue;
                        }

                        logger.LogInformation(
                            "Reconnected trusted peer {DeviceId} using persisted endpoint {Address}:{Port}.",
                            peerDeviceId,
                            endpoint.Address,
                            endpoint.Port);
                        break;
                    }
                    catch (OperationCanceledException) when (trustedReconnectToken.IsCancellationRequested)
                    {
                        return;
                    }
                    catch (Exception ex)
                    {
                        logger.LogDebug(
                            ex,
                            "Trusted reconnect attempt failed for {DeviceId} via {Address}:{Port}.",
                            peerDeviceId,
                            endpoint.Address,
                            endpoint.Port);
                    }
                }

                if (!transport.HasActiveSession(peerDeviceId))
                {
                    await Task.Delay(TrustedReconnectRetryDelay, trustedReconnectToken);
                }
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

    internal static bool ShouldAutoStartDiscovery(ITrustStore trustStore)
    {
        return !trustStore.GetAllPeers().Any(peer =>
            peer.State is TrustState.Trusted or TrustState.Blocked);
    }
}
