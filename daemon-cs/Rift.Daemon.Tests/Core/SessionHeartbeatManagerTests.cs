using System.Security.Cryptography.X509Certificates;
using Rift.Daemon.Core;
using Rift.Daemon.Core.Interfaces;
using Rift.Daemon.Core.Networking;

namespace Rift.Daemon.Tests.Core;

public sealed class SessionHeartbeatManagerTests
{
    [Fact]
    public void TimedOutSession_IsTrackedAgainAfterAuthenticatedTraffic()
    {
        long tick = 1_000;
        var presenceService = new PresenceService();
        var manager = new SessionHeartbeatManager(
            new FakeTransport(),
            new FakeIdentityManager(),
            presenceService,
            () => tick);
        var session = new SessionPeerContext(
            "rift-peer",
            [SessionHeartbeatManager.PresenceBasicCapability],
            allowsProtectedTraffic: true);

        manager.OnSessionStateChanged(new SessionStateChangedEventArgs(
            session.PeerDeviceId,
            isOnline: true,
            session.SelectedCapabilities,
            allowsProtectedTraffic: true));

        tick += (long)SessionHeartbeatManager.OfflineThreshold.TotalMilliseconds;
        manager.MarkTimedOutSessionsOffline();
        Assert.Equal("offline", presenceService.GetPeerPresence(session.PeerDeviceId)?.Status);

        manager.ObserveAuthenticatedMessage(session);
        presenceService.UpdatePeerPresence(
            session.PeerDeviceId,
            "online",
            DateTimeOffset.UtcNow.ToString("O"),
            session.SelectedCapabilities);

        tick += (long)SessionHeartbeatManager.OfflineThreshold.TotalMilliseconds;
        manager.MarkTimedOutSessionsOffline();
        Assert.Equal("offline", presenceService.GetPeerPresence(session.PeerDeviceId)?.Status);
    }

    [Fact]
    public void TimeoutTransition_DoesNotMarkReplacementSessionOffline()
    {
        long tick = 1_000;
        var presenceService = new PresenceService();
        var manager = new SessionHeartbeatManager(
            new FakeTransport(),
            new FakeIdentityManager(),
            presenceService,
            () => tick);
        var session = new SessionPeerContext(
            "rift-peer",
            [SessionHeartbeatManager.PresenceBasicCapability],
            allowsProtectedTraffic: true);
        var online = new SessionStateChangedEventArgs(
            session.PeerDeviceId,
            isOnline: true,
            session.SelectedCapabilities,
            allowsProtectedTraffic: true);

        manager.OnSessionStateChanged(online);
        var staleSession = manager.GetTrackedSession(session.PeerDeviceId);
        Assert.NotNull(staleSession);

        tick += (long)SessionHeartbeatManager.OfflineThreshold.TotalMilliseconds;
        manager.OnSessionStateChanged(online);
        presenceService.UpdatePeerPresence(
            session.PeerDeviceId,
            "online",
            DateTimeOffset.UtcNow.ToString("O"),
            session.SelectedCapabilities);

        var timedOut = manager.TryMarkSessionTimedOut(
            session.PeerDeviceId,
            staleSession!,
            staleSession.ReadLastHeardTick());

        Assert.False(timedOut);
        Assert.Equal("online", presenceService.GetPeerPresence(session.PeerDeviceId)?.Status);
    }

    [Fact]
    public void TimeoutTransition_DoesNotOverwriteNewAuthenticatedTraffic()
    {
        var tracked = new SessionHeartbeatManager.TrackedSession(
            [SessionHeartbeatManager.PresenceBasicCapability],
            now: 1_000);
        var observedLastHeardTick = tracked.ReadLastHeardTick();
        var markedOffline = false;

        tracked.MarkHeard(2_000);
        var timedOut = tracked.TryMarkTimedOut(
            observedLastHeardTick,
            () => markedOffline = true);

        Assert.False(timedOut);
        Assert.False(markedOffline);
        Assert.False(tracked.IsTimedOut);
        Assert.Equal(2_000, tracked.ReadLastHeardTick());
    }

    private sealed class FakeIdentityManager : IIdentityManager
    {
        public void EnsureIdentityInitialized() { }
        public string GetDeviceId() => "rift-local";
        public byte[] GetEd25519PublicKey() => [];
        public X509Certificate2 GetTlsCertificate() => throw new NotSupportedException();
        public byte[] SignEd25519(byte[] data) => [];
        public string GetFingerprint() => string.Empty;
        public string GetDisplayName() => string.Empty;
        public bool VerifyEd25519(byte[] publicKey, byte[] data, byte[] signature) => false;
    }

    private sealed class FakeTransport : ITransport
    {
        public event EventHandler<MessageReceivedEventArgs>? MessageReceived
        {
            add { }
            remove { }
        }

        public event EventHandler<SessionStateChangedEventArgs>? SessionStateChanged
        {
            add { }
            remove { }
        }

        public Task StartListeningAsync(CancellationToken cancellationToken) => Task.CompletedTask;
        public Task ConnectToPeerAsync(string host, int port, CancellationToken cancellationToken) => Task.CompletedTask;
        public Task<string> ConnectToPeerWithIdentityAsync(
            string host,
            int port,
            CancellationToken cancellationToken,
            string? expectedDeviceId = null) => Task.FromResult(string.Empty);
        public bool HasActiveSession(string peerDeviceId) => false;
        public bool HasProtectedSession(string peerDeviceId) => false;
        public void RefreshSessionAuthorization(string peerDeviceId) { }
        public PeerSessionEndpoint? GetPeerSessionEndpoint(string peerDeviceId) => null;
        public Task SendAsync(string peerDeviceId, ReadOnlyMemory<byte> frameBody, CancellationToken cancellationToken) => Task.CompletedTask;
        public Task DisconnectPeerAsync(string peerDeviceId, CancellationToken cancellationToken) => Task.CompletedTask;
    }
}
