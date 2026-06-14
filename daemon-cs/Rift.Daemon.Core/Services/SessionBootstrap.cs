using System;
using System.Threading;
using System.Threading.Tasks;
using Rift.Daemon.Core.Interfaces;

namespace Rift.Daemon.Core.Services;

public class SessionBootstrap
{
    private readonly IDiscoveryService _discoveryService;
    private readonly ITransport _transport;
    private readonly ITrustStore _trustStore;
    private readonly IIdentityManager _identityManager;

    public SessionBootstrap(
        IDiscoveryService discoveryService,
        ITransport transport,
        ITrustStore trustStore,
        IIdentityManager identityManager)
    {
        _discoveryService = discoveryService;
        _transport = transport;
        _trustStore = trustStore;
        _identityManager = identityManager;
        
        _transport.MessageReceived += Transport_MessageReceived;
    }

    public async Task StartAsync(CancellationToken cancellationToken)
    {
        _ = _transport.StartListeningAsync(cancellationToken);

        string deviceId = _identityManager.GetDeviceId();
        
        // Start advertising with the device id and protocol version
        _discoveryService.StartAdvertising(deviceId, "0.1", "0.1");
        
        // Start discovering other peers on the network
        _discoveryService.StartDiscovery();
    }

    private void Transport_MessageReceived(object? sender, MessageReceivedEventArgs e)
    {
        // Once a message is received, route it depending on the payload
        // This is part of the session lifecycle and protocol handling.
    }
}
