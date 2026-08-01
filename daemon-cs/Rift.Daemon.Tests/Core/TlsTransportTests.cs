using System.Text;
using Microsoft.Extensions.Logging.Abstractions;
using Rift.Daemon.Core.Cryptography;
using Rift.Daemon.Core.Interfaces;
using Rift.Daemon.Core.Networking;
using Rift.Daemon.Core.Protocol;
using Xunit;

namespace Rift.Daemon.Tests.Core;

public class TlsTransportTests
{
    [Fact]
    public void GetMaxInboundFrameSize_UsesPreAuthLimitUntilAuthenticated()
    {
        Assert.Equal(RiftFrame.MaxPreAuthSize, TlsTransport.GetMaxInboundFrameSize(isAuthenticated: false));
        Assert.Equal(RiftFrame.MaxPostAuthSize, TlsTransport.GetMaxInboundFrameSize(isAuthenticated: true));
    }

    [Fact]
    public void GetMaxOutboundFrameSize_UsesPreAuthLimitUntilAuthenticated()
    {
        Assert.Equal(RiftFrame.MaxPreAuthSize, TlsTransport.GetMaxOutboundFrameSize(isAuthenticated: false));
        Assert.Equal(RiftFrame.MaxPostAuthSize, TlsTransport.GetMaxOutboundFrameSize(isAuthenticated: true));
    }

    [Theory]
    [InlineData("session.hello")]
    [InlineData("session.accept")]
    public void ValidateFirstSessionControlMessage_AcceptsHandshakeMessages(string messageType)
    {
        TlsTransport.ValidateFirstSessionControlMessage(messageType);
    }

    [Fact]
    public void ValidateFirstSessionControlMessage_RejectsOtherMessages()
    {
        var exception = Assert.Throws<InvalidOperationException>(() =>
            TlsTransport.ValidateFirstSessionControlMessage("capability.advertise"));

        Assert.Equal(
            "Expected session.hello or session.accept but received capability.advertise.",
            exception.Message);
    }

    [Fact]
    public async Task CSharpPeers_EstablishProtectedSessionAndExchangeMessagesBidirectionally()
    {
        var serverIdentity = new IdentityManager();
        var clientIdentity = new IdentityManager();
        serverIdentity.EnsureIdentityInitialized();
        clientIdentity.EnsureIdentityInitialized();

        var serverTrust = CreateTrustStoreWithTrustedPeer(clientIdentity);
        var clientTrust = CreateTrustStoreWithTrustedPeer(serverIdentity);
        using var server = new TlsTransport(
            NullLogger<TlsTransport>.Instance,
            serverIdentity,
            serverTrust,
            listenPort: 0);
        using var client = new TlsTransport(
            NullLogger<TlsTransport>.Instance,
            clientIdentity,
            clientTrust);
        using var cancellation = new CancellationTokenSource(TimeSpan.FromSeconds(15));

        var serverOnline = OnlineSession(server, clientIdentity.GetDeviceId());
        var clientOnline = OnlineSession(client, serverIdentity.GetDeviceId());
        var serverMessage = NextMessage(server);
        var clientMessage = NextMessage(client);
        var listenerTask = server.StartListeningAsync(cancellation.Token);
        var port = await WaitForListeningPortAsync(server, cancellation.Token);

        var connectedDeviceId = await client.ConnectToPeerWithIdentityAsync(
            "127.0.0.1",
            port,
            cancellation.Token);
        await Task.WhenAll(serverOnline, clientOnline).WaitAsync(cancellation.Token);

        Assert.Equal(serverIdentity.GetDeviceId(), connectedDeviceId);
        Assert.True(server.HasProtectedSession(clientIdentity.GetDeviceId()));
        Assert.True(client.HasProtectedSession(serverIdentity.GetDeviceId()));

        var clientPayload = Encoding.UTF8.GetBytes("{\"type\":\"desktop.interop.client\"}");
        await client.SendAsync(serverIdentity.GetDeviceId(), clientPayload, cancellation.Token);
        var receivedByServer = await serverMessage.WaitAsync(cancellation.Token);

        Assert.Equal(clientIdentity.GetDeviceId(), receivedByServer.PeerDeviceId);
        Assert.Equal(clientPayload, receivedByServer.Payload.ToArray());
        Assert.True(receivedByServer.Session.AllowsProtectedTraffic);
        Assert.Contains("clipboard.offer_fetch", receivedByServer.Session.SelectedCapabilities);
        Assert.Contains("file.transfer", receivedByServer.Session.SelectedCapabilities);

        var serverPayload = Encoding.UTF8.GetBytes("{\"type\":\"desktop.interop.server\"}");
        await server.SendAsync(clientIdentity.GetDeviceId(), serverPayload, cancellation.Token);
        var receivedByClient = await clientMessage.WaitAsync(cancellation.Token);

        Assert.Equal(serverIdentity.GetDeviceId(), receivedByClient.PeerDeviceId);
        Assert.Equal(serverPayload, receivedByClient.Payload.ToArray());
        Assert.True(receivedByClient.Session.AllowsProtectedTraffic);

        await client.DisconnectPeerAsync(serverIdentity.GetDeviceId(), cancellation.Token);
        cancellation.Cancel();
        await listenerTask;
    }

    private static InMemoryTrustStore CreateTrustStoreWithTrustedPeer(IdentityManager peerIdentity)
    {
        var trustStore = new InMemoryTrustStore();
        trustStore.SavePeer(new PeerIdentity
        {
            DeviceId = peerIdentity.GetDeviceId(),
            Ed25519PublicKey = peerIdentity.GetEd25519PublicKey(),
            State = TrustState.Trusted,
            LastStateTransitionAt = DateTimeOffset.UtcNow
        });
        return trustStore;
    }

    private static Task<SessionStateChangedEventArgs> OnlineSession(
        TlsTransport transport,
        string peerDeviceId)
    {
        var completion = new TaskCompletionSource<SessionStateChangedEventArgs>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        transport.SessionStateChanged += (_, args) =>
        {
            if (args.IsOnline && args.PeerDeviceId == peerDeviceId)
            {
                completion.TrySetResult(args);
            }
        };
        return completion.Task;
    }

    private static Task<MessageReceivedEventArgs> NextMessage(TlsTransport transport)
    {
        var completion = new TaskCompletionSource<MessageReceivedEventArgs>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        transport.MessageReceived += (_, args) => completion.TrySetResult(args);
        return completion.Task;
    }

    private static async Task<int> WaitForListeningPortAsync(
        TlsTransport transport,
        CancellationToken cancellationToken)
    {
        int? port;
        while ((port = transport.ListeningPort) is null)
        {
            await Task.Delay(10, cancellationToken);
        }
        return port.Value;
    }

    private sealed class InMemoryTrustStore : ITrustStore
    {
        private readonly Dictionary<string, PeerIdentity> _peers = new(StringComparer.Ordinal);

        public void SavePeer(PeerIdentity peer) => _peers[peer.DeviceId] = peer;

        public void UpdateDisplayName(string deviceId, string newDisplayName)
        {
            if (_peers.TryGetValue(deviceId, out var peer))
            {
                peer.DisplayName = newDisplayName;
            }
        }

        public PeerIdentity? GetPeer(string deviceId) =>
            _peers.GetValueOrDefault(deviceId);

        public IEnumerable<PeerIdentity> GetAllPeers() => _peers.Values;

        public bool TryTransition(string deviceId, TrustState newState)
        {
            if (!_peers.TryGetValue(deviceId, out var peer))
            {
                return false;
            }
            peer.State = newState;
            return true;
        }

        public void RevokePeer(string deviceId, string revocationEvidence)
        {
            if (_peers.TryGetValue(deviceId, out var peer))
            {
                peer.State = TrustState.Revoked;
                peer.RevocationEvidence = revocationEvidence;
            }
        }

        public void DeletePeer(string deviceId) => _peers.Remove(deviceId);
    }
}
