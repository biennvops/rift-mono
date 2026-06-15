using System;
using System.Collections.Concurrent;
using System.IO;
using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Security.Cryptography.X509Certificates;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Extensions.Logging;
using Rift.Daemon.Core.Interfaces;
using Rift.Daemon.Core.Protocol;
using Rift.Daemon.Core.Cryptography;

namespace Rift.Daemon.Core.Networking;

public sealed class TlsTransport : ITransport, IDisposable
{
    private readonly ILogger<TlsTransport> _logger;
    private readonly IIdentityManager _identityManager;
    private TcpListener? _listener;
    private readonly ConcurrentDictionary<string, ActiveSession> _sessions = new();
    
    public event EventHandler<MessageReceivedEventArgs>? MessageReceived;

    public TlsTransport(ILogger<TlsTransport> logger, IIdentityManager identityManager)
    {
        _logger = logger;
        _identityManager = identityManager;
    }

    public async Task StartListeningAsync(CancellationToken cancellationToken)
    {
        _listener = new TcpListener(IPAddress.Any, 9140);
        _listener.Start();
        _logger.LogInformation("TlsTransport listening on port 9140.");

        try
        {
            while (!cancellationToken.IsCancellationRequested)
            {
                var client = await _listener.AcceptTcpClientAsync(cancellationToken);
                _ = HandleInboundConnectionAsync(client, cancellationToken);
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
        var client = new TcpClient();
        await client.ConnectAsync(host, port, cancellationToken);

        var stream = client.GetStream();
        var sslStream = new SslStream(stream, false, RemoteCertificateValidationCallback);

        var clientCert = _identityManager.GetTlsCertificate();

        var options = new SslClientAuthenticationOptions
        {
            TargetHost = host, // Could be instance name or anything, we don't validate hostname
            ClientCertificates = new X509CertificateCollection { clientCert },
            EnabledSslProtocols = SslProtocols.Tls13 | SslProtocols.Tls12,
            CertificateRevocationCheckMode = X509RevocationMode.NoCheck,
            RemoteCertificateValidationCallback = RemoteCertificateValidationCallback
        };

        await sslStream.AuthenticateAsClientAsync(options, cancellationToken);
        
        // Start reading loop in background
        _ = SessionLoopAsync(sslStream, client, cancellationToken);
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
        _sessions.TryAdd(deviceId, session);

        try
        {
            var headerBuffer = new byte[RiftFrame.LengthPrefixBytes];
            while (!cancellationToken.IsCancellationRequested)
            {
                int headerRead = await ReadExactAsync(sslStream, headerBuffer, cancellationToken);
                if (headerRead == 0) break; // EOF

                uint payloadLength = System.Buffers.Binary.BinaryPrimitives.ReadUInt32BigEndian(headerBuffer);
                // Currently setting limit to post-auth max size. We should strictly track auth state.
                if (payloadLength > RiftFrame.MaxPostAuthSize)
                {
                    throw new InvalidOperationException("PayloadTooLarge");
                }

                var payloadBuffer = new byte[payloadLength];
                int payloadRead = await ReadExactAsync(sslStream, payloadBuffer, cancellationToken);
                if (payloadRead == 0) break;

                MessageReceived?.Invoke(this, new MessageReceivedEventArgs(deviceId, payloadBuffer));
            }
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

    private string ExtractDeviceIdFromCertificate(X509Certificate2 cert)
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
                    return IdentityManager.DeriveDeviceId(edKeyBytes);
                }
            }
        }
        throw new InvalidOperationException("Certificate does not contain a valid Rift Ed25519 identity extension.");
    }

    public async Task SendAsync(string peerDeviceId, ReadOnlyMemory<byte> frameBody, CancellationToken cancellationToken)
    {
        if (_sessions.TryGetValue(peerDeviceId, out var session))
        {
            // Limit check
            if (frameBody.Length > RiftFrame.MaxPostAuthSize)
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
        _listener?.Stop();
        foreach (var session in _sessions.Values)
        {
            session.Dispose();
        }
        _sessions.Clear();
    }

    private class ActiveSession : IDisposable
    {
        public SslStream Stream { get; }
        public TcpClient Client { get; }
        public string DeviceId { get; }

        public ActiveSession(SslStream stream, TcpClient client, string deviceId)
        {
            Stream = stream;
            Client = client;
            DeviceId = deviceId;
        }

        public void Dispose()
        {
            Stream.Dispose();
            Client.Dispose();
        }
    }
}
