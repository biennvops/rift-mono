using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Extensions.Logging;
using Rift.Daemon.Core.Interfaces;
using Rift.Daemon.Core.Protocol;

namespace Rift.Daemon.Core.Networking;

public sealed class TlsTransport : ITransport, IDisposable
{
    private readonly ILogger<TlsTransport> _logger;
    private readonly IIdentityManager _identityManager;
    private readonly ITrustStore _trustStore;
    private readonly SessionBootstrap _bootstrap;
    private readonly ConcurrentDictionary<string, PeerSession> _sessions = new();
    private TcpListener? _listener;
    private CancellationTokenSource? _listeningCts;

    public event EventHandler<MessageReceivedEventArgs>? MessageReceived;

    public int ListeningPort => _listener?.LocalEndpoint is IPEndPoint ep ? ep.Port : 0;

    public TlsTransport(
        ILogger<TlsTransport> logger,
        IIdentityManager identityManager,
        ITrustStore trustStore,
        SessionBootstrap bootstrap)
    {
        _logger = logger;
        _identityManager = identityManager;
        _trustStore = trustStore;
        _bootstrap = bootstrap;
    }

    public async Task StartListeningAsync(CancellationToken cancellationToken)
    {
        _listener = new TcpListener(IPAddress.Any, 0); // Dynamic port
        _listener.Start();
        
        _logger.LogInformation("Rift TLS Listener started on port {Port}", ListeningPort);
        
        _listeningCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);

        try
        {
            while (!_listeningCts.IsCancellationRequested)
            {
                var client = await _listener.AcceptTcpClientAsync(_listeningCts.Token);
                _ = HandleInboundConnectionAsync(client, _listeningCts.Token);
            }
        }
        catch (OperationCanceledException) { }
        finally
        {
            _listener.Stop();
        }
    }

    private async Task HandleInboundConnectionAsync(TcpClient client, CancellationToken ct)
    {
        using (client)
        {
            try
            {
                var sslStream = new SslStream(client.GetStream(), false, ValidateRemoteCertificate);
                
                var options = new SslServerAuthenticationOptions
                {
                    ServerCertificate = _identityManager.GetTlsCertificate(),
                    ClientCertificateRequired = true,
                    EnabledSslProtocols = SslProtocols.Tls13 | SslProtocols.Tls12,
                    CertificateRevocationCheckMode = X509RevocationMode.NoCheck,
                    RemoteCertificateValidationCallback = ValidateRemoteCertificate
                };

                await sslStream.AuthenticateAsServerAsync(options, ct);
                
                await ProcessAuthenticatedSessionAsync(sslStream, ct);
            }
            catch (Exception ex)
            {
                _logger.LogWarning(ex, "Failed to handle inbound connection from {Endpoint}", client.Client.RemoteEndPoint);
            }
        }
    }

    private bool ValidateRemoteCertificate(object sender, X509Certificate? certificate, X509Chain? chain, SslPolicyErrors sslPolicyErrors)
    {
        // Mutual TLS requires a certificate.
        if (certificate == null) return false;
        
        // We defer full validation to post-handshake Ed25519 check, 
        // because we don't use CA-based trust.
        return true;
    }

    public async Task ConnectToPeerAsync(string host, int port, CancellationToken cancellationToken)
    {
        var client = new TcpClient();
        await client.ConnectAsync(host, port, cancellationToken);
        
        var sslStream = new SslStream(client.GetStream(), false, ValidateRemoteCertificate);
        
        var options = new SslClientAuthenticationOptions
        {
            TargetHost = host,
            ClientCertificates = new X509CertificateCollection { _identityManager.GetTlsCertificate() },
            EnabledSslProtocols = SslProtocols.Tls13 | SslProtocols.Tls12,
            CertificateRevocationCheckMode = X509RevocationMode.NoCheck,
            RemoteCertificateValidationCallback = ValidateRemoteCertificate
        };

        await sslStream.AuthenticateAsClientAsync(options, cancellationToken);
        
        // We don't wait for completion here; the session runs in background.
        _ = ProcessAuthenticatedSessionAsync(sslStream, cancellationToken, isClient: true);
    }

    private async Task ProcessAuthenticatedSessionAsync(SslStream sslStream, CancellationToken ct, bool isClient = false)
    {
        var remoteCert = sslStream.RemoteCertificate as X509Certificate2;
        if (remoteCert == null)
        {
            _logger.LogError("Peer did not provide a certificate.");
            return;
        }

        // Spec §5.2: Extract Ed25519 public key from extension
        byte[]? edPublicKey = ExtractEd25519PublicKey(remoteCert);
        if (edPublicKey == null)
        {
            _logger.LogCritical("auth.failed: Peer certificate missing or malformed Ed25519 extension.");
            return;
        }

        string deviceId = Cryptography.IdentityManager.DeriveDeviceId(edPublicKey);
        
        // Check if peer is blocked or revoked
        var peerRecord = _trustStore.GetPeer(deviceId);
        if (peerRecord != null && (peerRecord.State == TrustState.Blocked || peerRecord.State == TrustState.Revoked))
        {
            _logger.LogWarning("connection.rejected: Peer {DeviceId} is {State}", deviceId, peerRecord.State);
            return;
        }

        // Spec §5.3: Perform Session Bootstrap (Handshake, PoP, Capabilities)
        if (!await _bootstrap.AuthenticateSessionAsync(sslStream, deviceId, isClient, ct))
        {
             _logger.LogError("auth.failed: Session bootstrap failed for {DeviceId}", deviceId);
             return;
        }

        var session = new PeerSession(deviceId, sslStream, _logger)
        {
            IsAuthenticated = true
        };
        
        if (!_sessions.TryAdd(deviceId, session))
        {
            _logger.LogWarning("Session already exists for {DeviceId}. Closing old session.", deviceId);
            if (_sessions.TryRemove(deviceId, out var oldSession))
            {
                oldSession.Dispose();
            }
            _sessions.TryAdd(deviceId, session);
        }

        try
        {
            await session.ReceiveLoopAsync(args => MessageReceived?.Invoke(this, args), ct);
        }
        finally
        {
            _sessions.TryRemove(deviceId, out _);
            session.Dispose();
        }
    }

    public async Task SendAsync(string peerDeviceId, ReadOnlyMemory<byte> frameBody, CancellationToken cancellationToken)
    {
        if (!_sessions.TryGetValue(peerDeviceId, out var session))
        {
            throw new InvalidOperationException($"No open session exists for {peerDeviceId}");
        }

        await session.SendAsync(frameBody, cancellationToken);
    }

    public Task DisconnectPeerAsync(string peerDeviceId, CancellationToken cancellationToken)
    {
        if (_sessions.TryRemove(peerDeviceId, out var session))
        {
            session.Dispose();
        }
        return Task.CompletedTask;
    }

    private byte[]? ExtractEd25519PublicKey(X509Certificate2 cert)
    {
        // OID: 2.25.293029629918709742181702189012786017422
        var extension = cert.Extensions.FirstOrDefault(e => e.Oid?.Value == "2.25.293029629918709742181702189012786017422");
        if (extension == null) return null;

        // Spec §3.5: Inner encoding `04 20 <32 bytes>` (34 bytes)
        // Wrapped in outer OCTET STRING `04 22 04 20 <32 bytes>` (36 bytes)
        byte[] raw = extension.RawData;
        
        if (raw.Length != 36 || raw[0] != 0x04 || raw[1] != 34 || raw[2] != 0x04 || raw[3] != 32)
        {
             return null;
        }

        return raw.AsSpan(4, 32).ToArray();
    }

    public void Dispose()
    {
        _listeningCts?.Cancel();
        _listener?.Stop();
        foreach (var session in _sessions.Values)
        {
            session.Dispose();
        }
    }

    private class PeerSession(string deviceId, SslStream stream, ILogger logger) : IDisposable
    {
        private readonly SemaphoreSlim _sendLock = new(1, 1);
        public bool IsAuthenticated { get; init; }

        public async Task ReceiveLoopAsync(Action<MessageReceivedEventArgs> onMessage, CancellationToken ct)
        {
            byte[] lengthBuffer = new byte[RiftFrame.LengthPrefixBytes];

            while (!ct.IsCancellationRequested)
            {
                // Read 4-byte length prefix
                int read = await FullReadAsync(stream, lengthBuffer, ct);
                if (read == 0) break; // EOF

                uint payloadLength = System.Buffers.Binary.BinaryPrimitives.ReadUInt32BigEndian(lengthBuffer);
                int limit = IsAuthenticated ? RiftFrame.MaxPostAuthSize : RiftFrame.MaxPreAuthSize;

                if (payloadLength > (uint)limit)
                {
                    logger.LogCritical("PayloadTooLarge: Peer {DeviceId} sent {Size} bytes (limit {Limit})", deviceId, payloadLength, limit);
                    break;
                }

                byte[] payload = new byte[payloadLength];
                read = await FullReadAsync(stream, payload, ct);
                if (read < payloadLength) break; // Partial read/EOF

                onMessage(new MessageReceivedEventArgs(deviceId, payload));
            }
        }

        public async Task SendAsync(ReadOnlyMemory<byte> frameBody, CancellationToken ct)
        {
            byte[] fullFrame = RiftFrame.Encode(frameBody.Span);
            
            await _sendLock.WaitAsync(ct);
            try
            {
                await stream.WriteAsync(fullFrame, ct);
                await stream.FlushAsync(ct);
            }
            finally
            {
                _sendLock.Release();
            }
        }

        private async Task<int> FullReadAsync(Stream s, byte[] buffer, CancellationToken ct)
        {
            int totalRead = 0;
            while (totalRead < buffer.Length)
            {
                int read = await s.ReadAsync(buffer.AsMemory(totalRead), ct);
                if (read == 0) return totalRead;
                totalRead += read;
            }
            return totalRead;
        }

        public void Dispose()
        {
            stream.Dispose();
            _sendLock.Dispose();
        }
    }
}
