using System;
using System.Collections.Concurrent;
using System.IO;
using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Security.Cryptography.X509Certificates;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;
using Rift.Daemon.Core.Interfaces;
using Rift.Daemon.Core.Protocol;
using Rift.Daemon.Core.Cryptography;

namespace Rift.Daemon.Core.Networking;

public sealed class TlsTransport : ITransport, IDisposable
{
    private readonly ILogger<TlsTransport> _logger;
    private readonly IIdentityManager _identityManager;
    private readonly SessionBootstrap _sessionBootstrap;
    private readonly CancellationTokenSource _shutdownCts = new();
    private TcpListener? _listener;
    private readonly ConcurrentDictionary<string, ActiveSession> _sessions = new();
    private readonly ConcurrentDictionary<int, Task> _backgroundTasks = new();
    private int _nextBackgroundTaskId;
    
    public event EventHandler<MessageReceivedEventArgs>? MessageReceived;

    public TlsTransport(ILogger<TlsTransport> logger, IIdentityManager identityManager)
    {
        _logger = logger;
        _identityManager = identityManager;
        _sessionBootstrap = new SessionBootstrap(NullLogger<SessionBootstrap>.Instance, identityManager);
    }

    public async Task StartListeningAsync(CancellationToken cancellationToken)
    {
        using var linkedCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, _shutdownCts.Token);
        var linkedToken = linkedCts.Token;

        _listener = new TcpListener(IPAddress.Any, RiftNetworkDefaults.DefaultPort);
        _listener.Start();
        _logger.LogInformation("TlsTransport listening on port {Port}.", RiftNetworkDefaults.DefaultPort);

        try
        {
            while (!linkedToken.IsCancellationRequested)
            {
                var client = await _listener.AcceptTcpClientAsync(linkedToken);
                TrackBackgroundTask(HandleInboundConnectionAsync(client, linkedToken), "inbound connection");
            }
        }
        catch (OperationCanceledException)
        {
            // Normal shutdown
        }
        finally
        {
            _listener.Stop();
        }
    }

    private async Task HandleInboundConnectionAsync(TcpClient client, CancellationToken cancellationToken)
    {
        try
        {
            var stream = client.GetStream();
            var sslStream = new SslStream(stream, false, RemoteCertificateValidationCallback);
            
            var serverCert = _identityManager.GetTlsCertificate();
            
            // Spec §5.1: Mutual TLS with TLS 1.3 preferred.
            await sslStream.AuthenticateAsServerAsync(new SslServerAuthenticationOptions
            {
                ServerCertificate = serverCert,
                ClientCertificateRequired = true,
                EnabledSslProtocols = SslProtocols.Tls13 | SslProtocols.Tls12,
                CertificateRevocationCheckMode = X509RevocationMode.NoCheck // Peer certs are self-signed
            }, cancellationToken);

            await SessionLoopAsync(sslStream, client, cancellationToken);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to authenticate inbound TLS connection.");
            client.Close();
        }
    }

    public async Task ConnectToPeerAsync(string host, int port, CancellationToken cancellationToken)
    {
        using var linkedCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, _shutdownCts.Token);
        var linkedToken = linkedCts.Token;
        var client = new TcpClient();
        SslStream? sslStream = null;

        try
        {
            await client.ConnectAsync(host, port, linkedToken);

            var stream = client.GetStream();
            sslStream = new SslStream(stream, false, RemoteCertificateValidationCallback);

            var clientCert = _identityManager.GetTlsCertificate();

            var options = new SslClientAuthenticationOptions
            {
                TargetHost = host, // Could be instance name or anything, we don't validate hostname
                ClientCertificates = new X509CertificateCollection { clientCert },
                EnabledSslProtocols = SslProtocols.Tls13 | SslProtocols.Tls12,
                CertificateRevocationCheckMode = X509RevocationMode.NoCheck
            };

            await sslStream.AuthenticateAsClientAsync(options, linkedToken);

            var remoteCert = sslStream.RemoteCertificate as X509Certificate2 ??
                X509CertificateLoader.LoadCertificate(sslStream.RemoteCertificate!.GetRawCertData());
            var deviceId = ExtractDeviceIdFromCertificate(remoteCert);
            var session = new ActiveSession(sslStream, client, deviceId);

            await CompleteSessionHandshakeAsync(session, remoteCert, linkedToken);
            if (!_sessions.TryAdd(deviceId, session))
            {
                session.Dispose();
                throw new InvalidOperationException($"A session for {deviceId} is already registered.");
            }

            TrackBackgroundTask(RunRegisteredSessionLoopAsync(session, linkedToken), "outbound session loop");
        }
        catch
        {
            sslStream?.Dispose();
            client.Dispose();
            throw;
        }
    }

    private async Task SessionLoopAsync(SslStream sslStream, TcpClient client, CancellationToken cancellationToken)
    {
        var remoteCert = sslStream.RemoteCertificate as X509Certificate2 ?? X509CertificateLoader.LoadCertificate(sslStream.RemoteCertificate!.GetRawCertData());
        string deviceId;
        try
        {
            deviceId = ExtractDeviceIdFromCertificate(remoteCert);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to extract identity from peer certificate.");
            client.Close();
            return;
        }

        var session = new ActiveSession(sslStream, client, deviceId);

        try
        {
            await CompleteSessionHandshakeAsync(session, remoteCert, cancellationToken);
            _sessions.TryAdd(deviceId, session);
            await RunRegisteredSessionLoopAsync(session, cancellationToken);
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Session loop error for peer {DeviceId}", deviceId);
        }
        finally
        {
            _sessions.TryRemove(deviceId, out _);
            session.Dispose();
        }
    }

    private async Task CompleteSessionHandshakeAsync(ActiveSession session, X509Certificate2 remoteCert, CancellationToken cancellationToken)
    {
        await _sessionBootstrap.SendSessionHelloAsync(session.Stream, cancellationToken);

        var helloPayload = await ReadFramePayloadAsync(session.Stream, RiftFrame.MaxPreAuthSize, cancellationToken);
        if (helloPayload is null)
        {
            throw new InvalidOperationException("Peer closed connection before sending session.hello.");
        }

        VerifySessionControlMessage(session.Stream, remoteCert, helloPayload, expectedType: "session.hello");

        await _sessionBootstrap.SendSessionAcceptAsync(session.Stream, cancellationToken);

        var acceptPayload = await ReadFramePayloadAsync(session.Stream, RiftFrame.MaxPreAuthSize, cancellationToken);
        if (acceptPayload is null)
        {
            throw new InvalidOperationException("Peer closed connection before sending session.accept.");
        }

        VerifySessionControlMessage(session.Stream, remoteCert, acceptPayload, expectedType: "session.accept");
        session.IsAuthenticated = true;
    }

    private async Task RunRegisteredSessionLoopAsync(ActiveSession session, CancellationToken cancellationToken)
    {
        while (!cancellationToken.IsCancellationRequested)
        {
            var payloadBuffer = await ReadFramePayloadAsync(session.Stream, GetMaxInboundFrameSize(session.IsAuthenticated), cancellationToken);
            if (payloadBuffer is null)
            {
                break;
            }

            MessageReceived?.Invoke(this, new MessageReceivedEventArgs(session.DeviceId, payloadBuffer));
        }
    }

    private void VerifySessionControlMessage(SslStream sslStream, X509Certificate2 remoteCert, byte[] payloadBuffer, string expectedType)
    {
        try
        {
            using var document = JsonDocument.Parse(payloadBuffer);
            var root = document.RootElement;

            var messageType = root.GetProperty("type").GetString();
            if (!string.Equals(messageType, expectedType, StringComparison.Ordinal))
            {
                throw new InvalidOperationException($"Expected {expectedType} but received {messageType ?? "<null>"}.");
            }

            var payload = root.GetProperty("payload");
            var identityProofHex = payload.GetProperty("identityProof").GetString();
            if (string.IsNullOrWhiteSpace(identityProofHex))
            {
                throw new InvalidOperationException($"{expectedType} did not include identityProof.");
            }

            var signatureBytes = Convert.FromHexString(identityProofHex);
            var peerEd25519PubKey = ExtractEd25519PublicKeyFromCertificate(remoteCert);
            if (!_sessionBootstrap.VerifyIdentityProof(sslStream, peerEd25519PubKey, remoteCert, signatureBytes))
            {
                throw new InvalidOperationException($"{expectedType} identityProof verification failed.");
            }
        }
        catch (KeyNotFoundException ex)
        {
            throw new InvalidOperationException($"{expectedType} payload was missing required fields.", ex);
        }
        catch (JsonException ex)
        {
            throw new InvalidOperationException($"{expectedType} payload was not valid JSON.", ex);
        }
        catch (FormatException ex)
        {
            throw new InvalidOperationException($"{expectedType} identityProof was not valid lowercase hexadecimal.", ex);
        }
    }

    private static async Task<byte[]?> ReadFramePayloadAsync(Stream stream, int maxFrameSize, CancellationToken cancellationToken)
    {
        var headerBuffer = new byte[RiftFrame.LengthPrefixBytes];
        int headerRead = await ReadExactAsync(stream, headerBuffer, cancellationToken);
        if (headerRead == 0)
        {
            return null;
        }

        uint payloadLength = System.Buffers.Binary.BinaryPrimitives.ReadUInt32BigEndian(headerBuffer);
        if (payloadLength > maxFrameSize)
        {
            throw new InvalidOperationException("PayloadTooLarge");
        }

        var payloadBuffer = new byte[payloadLength];
        int payloadRead = await ReadExactAsync(stream, payloadBuffer, cancellationToken);
        if (payloadRead == 0)
        {
            return null;
        }

        return payloadBuffer;
    }

    private static async Task<int> ReadExactAsync(Stream stream, byte[] buffer, CancellationToken cancellationToken)
    {
        int totalRead = 0;
        while (totalRead < buffer.Length)
        {
            int read = await stream.ReadAsync(buffer, totalRead, buffer.Length - totalRead, cancellationToken);
            if (read == 0) return 0;
            totalRead += read;
        }
        return totalRead;
    }

    private bool RemoteCertificateValidationCallback(object sender, X509Certificate? certificate, X509Chain? chain, SslPolicyErrors sslPolicyErrors)
    {
        // For Rift, we do not require the certificate to be signed by a trusted CA.
        // We only care about extracting the Ed25519 identity. The actual trust is evaluated post-handshake.
        return certificate != null;
    }

    internal static string ExtractDeviceIdFromCertificate(X509Certificate2 cert)
    {
        var edKeyBytes = ExtractEd25519PublicKeyFromCertificate(cert);
        return IdentityManager.DeriveDeviceId(edKeyBytes);
    }

    internal static byte[] ExtractEd25519PublicKeyFromCertificate(X509Certificate2 cert)
    {
        foreach (var ext in cert.Extensions)
        {
            if (ext.Oid?.Value == "2.25.293029629918709742181702189012786017422")
            {
                // Spec appendix A: OCTET STRING containing 04 20 <32-byte Ed25519 key>
                var rawData = ext.RawData; // Inner 34 bytes
                if (rawData.Length == 34 && rawData[0] == 0x04 && rawData[1] == 0x20)
                {
                    var edKeyBytes = new byte[32];
                    Array.Copy(rawData, 2, edKeyBytes, 0, 32);
                    return edKeyBytes;
                }
            }
        }
        throw new InvalidOperationException("Certificate does not contain a valid Rift Ed25519 identity extension.");
    }

    public async Task SendAsync(string peerDeviceId, ReadOnlyMemory<byte> frameBody, CancellationToken cancellationToken)
    {
        if (_sessions.TryGetValue(peerDeviceId, out var session))
        {
            int maxFrameSize = GetMaxOutboundFrameSize(session.IsAuthenticated);
            if (frameBody.Length > maxFrameSize)
                throw new InvalidOperationException("PayloadTooLarge");
                 
            var frame = RiftFrame.Encode(frameBody.Span);
            await session.Stream.WriteAsync(frame, cancellationToken);
        }
        else
        {
            throw new InvalidOperationException($"No open session exists for {peerDeviceId}.");
        }
    }

    public Task DisconnectPeerAsync(string peerDeviceId, CancellationToken cancellationToken)
    {
        if (_sessions.TryRemove(peerDeviceId, out var session))
        {
            session.Dispose();
        }
        return Task.CompletedTask;
    }

    public void Dispose()
    {
        _shutdownCts.Cancel();
        _listener?.Stop();
        WaitForBackgroundTasks();
        foreach (var session in _sessions.Values)
        {
            session.Dispose();
        }
        _sessions.Clear();
        _shutdownCts.Dispose();
    }

    private void TrackBackgroundTask(Task task, string operation)
    {
        int taskId = Interlocked.Increment(ref _nextBackgroundTaskId);
        _backgroundTasks.TryAdd(taskId, task);

        _ = task.ContinueWith(
            completedTask =>
            {
                _backgroundTasks.TryRemove(taskId, out _);

                if (completedTask.IsFaulted)
                {
                    _logger.LogError(completedTask.Exception, "Background task failed during {Operation}.", operation);
                }
            },
            CancellationToken.None,
            TaskContinuationOptions.ExecuteSynchronously,
            TaskScheduler.Default);
    }

    private void WaitForBackgroundTasks()
    {
        var pendingTasks = _backgroundTasks.Values.ToArray();
        if (pendingTasks.Length == 0)
        {
            return;
        }

        try
        {
            Task.WhenAll(pendingTasks).GetAwaiter().GetResult();
        }
        catch (Exception ex)
        {
            _logger.LogDebug(ex, "Observed background task completion during transport disposal.");
        }
    }

    internal static int GetMaxInboundFrameSize(bool isAuthenticated)
    {
        return isAuthenticated ? RiftFrame.MaxPostAuthSize : RiftFrame.MaxPreAuthSize;
    }

    internal static int GetMaxOutboundFrameSize(bool isAuthenticated)
    {
        return isAuthenticated ? RiftFrame.MaxPostAuthSize : RiftFrame.MaxPreAuthSize;
    }

    private class ActiveSession : IDisposable
    {
        public SslStream Stream { get; }
        public TcpClient Client { get; }
        public string DeviceId { get; }
        public bool IsAuthenticated { get; set; }

        public ActiveSession(SslStream stream, TcpClient client, string deviceId)
        {
            Stream = stream;
            Client = client;
            DeviceId = deviceId;
            IsAuthenticated = false;
        }

        public void Dispose()
        {
            Stream.Dispose();
            Client.Dispose();
        }
    }
}
