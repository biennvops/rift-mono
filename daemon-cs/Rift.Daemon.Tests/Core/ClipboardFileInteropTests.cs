using System.Security.Cryptography;
using System.Text;
using System.Threading.Channels;
using Microsoft.Data.Sqlite;
using Microsoft.Extensions.Logging.Abstractions;
using Rift.Daemon.Core;
using Rift.Daemon.Core.Cryptography;
using Rift.Daemon.Core.Data;
using Rift.Daemon.Core.Interfaces;
using Rift.Daemon.Core.Networking;

namespace Rift.Daemon.Tests.Core;

/// <summary>
/// Desktop-to-desktop interop scenario: two trusted daemon-core stacks exchange
/// clipboard content (text and binary) and a chunked file transfer over the
/// real TLS transport with production message routing.
/// </summary>
[Collection("LiveTransportInterop")]
public sealed class ClipboardFileInteropTests : IDisposable
{
    // Generous: loopback traffic is fast, but parallel suite load can starve
    // TLS handshakes on CI machines.
    private static readonly TimeSpan ScenarioTimeout = TimeSpan.FromSeconds(90);

    private readonly FullPeerStack _sender;
    private readonly FullPeerStack _receiver;

    public ClipboardFileInteropTests()
    {
        _sender = new FullPeerStack("sender");
        _receiver = new FullPeerStack("receiver");
        _sender.TrustPeer(_receiver.Identity);
        _receiver.TrustPeer(_sender.Identity);
    }

    public void Dispose()
    {
        _sender.Dispose();
        _receiver.Dispose();
    }

    [Fact]
    public async Task TrustedDesktopPeers_SyncClipboardTextAndBinary()
    {
        using var cancellation = new CancellationTokenSource(ScenarioTimeout);
        var token = cancellation.Token;
        var listenerTask = await ConnectAsync(token);

        // Text offer/fetch.
        var textBytes = Encoding.UTF8.GetBytes("Desktop clipboard parity: xin chào 🚀");
        await SyncClipboardPayloadAsync("text/plain", textBytes, token);

        // Binary (PNG-style) offer/fetch with a fresh offer sequence.
        var binaryBytes = new byte[64 * 1024];
        RandomNumberGenerator.Fill(binaryBytes);
        await SyncClipboardPayloadAsync("image/png", binaryBytes, token);

        cancellation.Cancel();
        await listenerTask;
    }

    [Fact]
    public async Task TrustedDesktopPeers_TransferFileWithVerifiedHash()
    {
        using var cancellation = new CancellationTokenSource(ScenarioTimeout);
        var token = cancellation.Token;
        var listenerTask = await ConnectAsync(token);

        var payload = new byte[700_000]; // Forces multiple chunks.
        RandomNumberGenerator.Fill(payload);
        var sourcePath = Path.Combine(Path.GetTempPath(), $"rift-interop-src-{Guid.NewGuid():N}.bin");
        var destinationPath = Path.Combine(Path.GetTempPath(), $"rift-interop-dst-{Guid.NewGuid():N}.bin");
        await File.WriteAllBytesAsync(sourcePath, payload, token);

        try
        {
            var offerResult = await _sender.FileTransfer.OfferFileAsync(
                _receiver.DeviceId,
                sourcePath,
                "parity.bin",
                "application/octet-stream",
                token);

            await WaitForConditionAsync(
                async () => (await _receiver.FileTransfer.ListIncomingFileOffersAsync()).Offers
                    .Any(offer => offer.TransferId == offerResult.TransferId),
                token);
            var incoming = (await _receiver.FileTransfer.ListIncomingFileOffersAsync()).Offers
                .Single(offer => offer.TransferId == offerResult.TransferId);

            Assert.Equal("parity.bin", incoming.FileName);
            Assert.Equal(payload.Length, incoming.ByteSize);
            Assert.Equal(Sha256Hex(payload), incoming.Sha256);

            var completed = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            _receiver.FileTransfer.TransferUpdated += (_, args) =>
            {
                if (args.TransferId == offerResult.TransferId && args.State == "done")
                {
                    completed.TrySetResult();
                }
            };

            await _receiver.FileTransfer.AcceptFileOfferAsync(
                offerResult.TransferId,
                destinationPath,
                overwrite: false,
                token);
            await completed.Task.WaitAsync(token);

            var received = await File.ReadAllBytesAsync(destinationPath, token);
            Assert.Equal(payload, received);
            await WaitForConditionAsync(
                () => Task.FromResult(
                    _sender.Operations.GetOperation(offerResult.OperationId).State == "Done"),
                token);
        }
        finally
        {
            File.Delete(sourcePath);
            if (File.Exists(destinationPath))
            {
                File.Delete(destinationPath);
            }
        }

        cancellation.Cancel();
        await listenerTask;
    }

    private async Task<Task> ConnectAsync(CancellationToken token)
    {
        var listenerTask = _receiver.Transport.StartListeningAsync(token);
        var port = await _receiver.WaitForListeningPortAsync(token);

        var online = _sender.WaitForSessionOnline(_receiver.DeviceId);
        await _sender.Transport.ConnectToPeerWithIdentityAsync("127.0.0.1", port, token);
        var session = await online.WaitAsync(token);

        Assert.True(session.AllowsProtectedTraffic);
        await WaitForConditionAsync(
            () => Task.FromResult(_receiver.Transport.HasProtectedSession(_sender.DeviceId)),
            token);
        return listenerTask;
    }

    private async Task SyncClipboardPayloadAsync(string contentType, byte[] payload, CancellationToken token)
    {
        var sha256 = Sha256Hex(payload);
        var result = await _sender.Clipboard.NotifyClipboardChangeAsync(
            contentType,
            payload.Length,
            sha256,
            Convert.ToBase64String(payload),
            token);

        Assert.Contains(_receiver.DeviceId, result.BroadcastTo);

        await WaitForConditionAsync(
            async () => (await _receiver.Clipboard.ListClipboardOffersAsync()).Offers
                .Any(offer => offer.OfferId == result.OfferId),
            token);
        var offer = (await _receiver.Clipboard.ListClipboardOffersAsync()).Offers
            .Single(candidate => candidate.OfferId == result.OfferId);

        Assert.Equal(_sender.DeviceId, offer.SourceDeviceId);
        Assert.Equal(contentType, offer.ContentType);
        Assert.Equal(payload.Length, offer.ByteSize);
        Assert.Equal(sha256, offer.Sha256);

        var fetched = await _receiver.Clipboard.FetchClipboardContentAsync(result.OfferId, token);

        Assert.True(fetched.Verified);
        Assert.Equal(sha256, fetched.Sha256);
        Assert.Equal(payload, Convert.FromBase64String(fetched.ContentBase64));
    }

    private static string Sha256Hex(byte[] payload) =>
        Convert.ToHexStringLower(SHA256.HashData(payload));

    private static async Task WaitForConditionAsync(Func<Task<bool>> condition, CancellationToken cancellationToken)
    {
        while (!await condition())
        {
            await Task.Delay(20, cancellationToken);
        }
    }

    /// <summary>
    /// A daemon-core stack wired like the production Worker: real transport,
    /// SQLite persistence, protocol router, presence tracking, and the
    /// clipboard/file-transfer services under test.
    /// </summary>
    private sealed class FullPeerStack : IDisposable
    {
        private readonly string _databasePath;
        private readonly PairingProtocolCoordinator _pairing;
        private readonly Channel<(SessionPeerContext Session, byte[] Payload)> _inbound =
            Channel.CreateUnbounded<(SessionPeerContext, byte[])>(new UnboundedChannelOptions
            {
                SingleReader = true
            });
        private readonly CancellationTokenSource _dispatchCts = new();
        private readonly Task _dispatchLoop;

        public FullPeerStack(string name)
        {
            _databasePath = Path.Combine(Path.GetTempPath(), $"rift-clip-file-interop-{name}-{Guid.NewGuid():N}.db");
            var databaseContext = new DatabaseContext(_databasePath);
            databaseContext.Initialize();
            TrustStore = new SqliteTrustStore(databaseContext);
            Identity = new IdentityManager(new SqliteLocalIdentityStore(databaseContext));
            Identity.EnsureIdentityInitialized();
            Transport = new TlsTransport(
                NullLogger<TlsTransport>.Instance,
                Identity,
                TrustStore,
                securityEventLog: null,
                listenPort: 0);

            var securityEventLog = new NoOpSecurityEventLog();
            var discovery = new EmptyDiscoveryCoordinator();
            Presence = new PresenceService();
            Operations = new OperationService();
            Clipboard = new ClipboardService(
                Transport,
                TrustStore,
                discovery,
                Presence,
                Identity,
                securityEventLog,
                Operations);
            FileTransfer = new FileTransferService(
                Transport,
                TrustStore,
                discovery,
                Presence,
                Identity,
                securityEventLog,
                Operations);
            _pairing = new PairingProtocolCoordinator(
                Transport,
                discovery,
                TrustStore,
                Identity,
                securityEventLog);
            var mediaPlayback = new MediaPlaybackSyncService(
                Transport,
                Presence,
                Identity,
                Operations,
                securityEventLog);
            var notificationSync = new NotificationSyncService(
                Transport,
                Presence,
                Identity,
                Operations,
                securityEventLog);
            Router = new ProtocolMessageRouter(
                _pairing,
                Presence,
                Clipboard,
                FileTransfer,
                mediaPlayback,
                notificationSync);

            Transport.MessageReceived += OnMessageReceived;
            Transport.SessionStateChanged += OnSessionStateChanged;
            _dispatchLoop = Task.Run(DispatchInboundAsync);
        }

        public SqliteTrustStore TrustStore { get; }

        public IdentityManager Identity { get; }

        public TlsTransport Transport { get; }

        public PresenceService Presence { get; }

        public OperationService Operations { get; }

        public ClipboardService Clipboard { get; }

        public FileTransferService FileTransfer { get; }

        public ProtocolMessageRouter Router { get; }

        public string DeviceId => Identity.GetDeviceId();

        public void TrustPeer(IdentityManager peerIdentity)
        {
            TrustStore.SavePeer(new PeerIdentity
            {
                DeviceId = peerIdentity.GetDeviceId(),
                Ed25519PublicKey = peerIdentity.GetEd25519PublicKey(),
                State = TrustState.Trusted,
                LastStateTransitionAt = DateTimeOffset.UtcNow
            });
        }

        public Task<SessionStateChangedEventArgs> WaitForSessionOnline(string peerDeviceId)
        {
            var completion = new TaskCompletionSource<SessionStateChangedEventArgs>(
                TaskCreationOptions.RunContinuationsAsynchronously);
            Transport.SessionStateChanged += (_, args) =>
            {
                if (args.IsOnline && args.PeerDeviceId == peerDeviceId)
                {
                    completion.TrySetResult(args);
                }
            };
            return completion.Task;
        }

        public async Task<int> WaitForListeningPortAsync(CancellationToken cancellationToken)
        {
            int? port;
            while ((port = Transport.ListeningPort) is null)
            {
                await Task.Delay(10, cancellationToken);
            }
            return port.Value;
        }

        public void Dispose()
        {
            Transport.MessageReceived -= OnMessageReceived;
            Transport.SessionStateChanged -= OnSessionStateChanged;
            _inbound.Writer.TryComplete();
            _dispatchCts.Cancel();
            try
            {
                _dispatchLoop.Wait(TimeSpan.FromSeconds(5));
            }
            catch (AggregateException)
            {
                // Cancellation during shutdown is expected.
            }
            _dispatchCts.Dispose();
            _pairing.Dispose();
            Transport.Dispose();
            SqliteConnection.ClearAllPools();
            if (File.Exists(_databasePath))
            {
                File.Delete(_databasePath);
            }
        }

        private void OnMessageReceived(object? sender, MessageReceivedEventArgs args)
        {
            // Chunked file transfers rely on strictly ordered processing, so
            // inbound frames are queued in arrival order and drained by a
            // single dispatcher (Task.Run + semaphore does not preserve FIFO).
            _inbound.Writer.TryWrite((args.Session, args.Payload.ToArray()));
        }

        private async Task DispatchInboundAsync()
        {
            await foreach (var (session, payload) in _inbound.Reader.ReadAllAsync(_dispatchCts.Token))
            {
                try
                {
                    await Router.HandleMessageAsync(session, payload, _dispatchCts.Token);
                }
                catch (OperationCanceledException) when (_dispatchCts.IsCancellationRequested)
                {
                    return;
                }
                catch
                {
                    // Router-level rejections are validated through service state.
                }
            }
        }

        private void OnSessionStateChanged(object? sender, SessionStateChangedEventArgs args)
        {
            // Mirrors Worker presence bookkeeping so capability checks work.
            if (args.IsOnline)
            {
                Presence.UpdatePeerPresence(
                    args.PeerDeviceId,
                    "online",
                    DateTimeOffset.UtcNow.ToString("O"),
                    args.SelectedCapabilities);
            }
            else
            {
                Presence.MarkPeerOffline(args.PeerDeviceId);
            }
        }
    }

    private sealed class EmptyDiscoveryCoordinator : IDiscoveryCoordinator
    {
        public DiscoveryToggleResult StartDiscovery() => new() { Started = false };

        public DiscoveryToggleResult StopDiscovery() => new() { Stopped = false };

        public ListDiscoveredPeersResult ListDiscoveredPeers() => new();

        public bool TryGetDiscoveredPeer(string deviceId, out DiscoveredPeerInfo? peer)
        {
            peer = null;
            return false;
        }
    }
}
