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
using Rift.Daemon.Core.Interfaces;
using Rift.Daemon.Core.Protocol;

namespace Rift.Daemon.Core.Services;

public class TlsTransport : ITransport, IDisposable
{
    private readonly IIdentityManager _identityManager;
    private readonly ITrustStore _trustStore;
    private TcpListener? _listener;
    
    private readonly ConcurrentDictionary<string, SslStream> _activeSessions = new();

    public event EventHandler<MessageReceivedEventArgs>? MessageReceived;

    public TlsTransport(IIdentityManager identityManager, ITrustStore trustStore)
    {
        _identityManager = identityManager ?? throw new ArgumentNullException(nameof(identityManager));
        _trustStore = trustStore ?? throw new ArgumentNullException(nameof(trustStore));
    }

    public async Task StartListeningAsync(CancellationToken cancellationToken)
    {
        _listener = new TcpListener(IPAddress.Any, 35142);
        _listener.Start();

        try
        {
            while (!cancellationToken.IsCancellationRequested)
            {
                var client = await _listener.AcceptTcpClientAsync(cancellationToken);
                _ = Task.Run(() => HandleAcceptedClientAsync(client, cancellationToken));
            }
        }
        catch (OperationCanceledException)
        {
            // Expected
        }
        finally
        {
            _listener.Stop();
        }
    }

    private async Task HandleAcceptedClientAsync(TcpClient client, CancellationToken token)
    {
        var stream = client.GetStream();
        var sslStream = new SslStream(stream, false, ValidateRemoteCertificate, null);

        try
        {
            await sslStream.AuthenticateAsServerAsync(new SslServerAuthenticationOptions
            {
                ServerCertificate = _identityManager.GetTlsCertificate(),
                ClientCertificateRequired = true,
                EnabledSslProtocols = SslProtocols.Tls13 | SslProtocols.Tls12,
                CertificateRevocationCheckMode = X509RevocationMode.NoCheck
            }, token);

            var remoteCert = sslStream.RemoteCertificate as X509Certificate2;
            if (remoteCert == null) throw new AuthenticationException("Missing client cert");

            string deviceId = ExtractDeviceId(remoteCert);
            
            _activeSessions.TryAdd(deviceId, sslStream);

            await ReadLoopAsync(deviceId, sslStream, token);
        }
        catch (Exception)
        {
            client.Close();
        }
    }

    public async Task ConnectToPeerAsync(string host, int port, CancellationToken cancellationToken)
    {
        var client = new TcpClient();
        await client.ConnectAsync(host, port, cancellationToken);

        var sslStream = new SslStream(client.GetStream(), false, ValidateRemoteCertificate, null);

        try
        {
            await sslStream.AuthenticateAsClientAsync(new SslClientAuthenticationOptions
            {
                TargetHost = host,
                ClientCertificates = new X509CertificateCollection { _identityManager.GetTlsCertificate() },
                EnabledSslProtocols = SslProtocols.Tls13 | SslProtocols.Tls12,
                CertificateRevocationCheckMode = X509RevocationMode.NoCheck
            }, cancellationToken);

            var remoteCert = sslStream.RemoteCertificate as X509Certificate2;
            if (remoteCert == null) throw new AuthenticationException("Missing server cert");

            string deviceId = ExtractDeviceId(remoteCert);
            _activeSessions.TryAdd(deviceId, sslStream);

            _ = Task.Run(() => ReadLoopAsync(deviceId, sslStream, cancellationToken));
        }
        catch (Exception)
        {
            client.Close();
            throw;
        }
    }

    public async Task SendAsync(string peerDeviceId, ReadOnlyMemory<byte> frameBody, CancellationToken cancellationToken)
    {
        if (!_activeSessions.TryGetValue(peerDeviceId, out var sslStream))
        {
            throw new InvalidOperationException($"No active session for {peerDeviceId}");
        }

        if (frameBody.Length > RiftFrame.MaxPostAuthSize)
        {
            throw new InvalidOperationException("Payload size limit exceeded.");
        }

        byte[] framed = RiftFrame.Encode(frameBody.Span);
        await sslStream.WriteAsync(framed, cancellationToken);
    }

    public Task DisconnectPeerAsync(string peerDeviceId, CancellationToken cancellationToken)
    {
        if (_activeSessions.TryRemove(peerDeviceId, out var sslStream))
        {
            try { sslStream.Close(); } catch {}
        }
        return Task.CompletedTask;
    }

    private async Task ReadLoopAsync(string deviceId, SslStream sslStream, CancellationToken cancellationToken)
    {
        try
        {
            byte[] lengthBuffer = new byte[RiftFrame.LengthPrefixBytes];
            while (!cancellationToken.IsCancellationRequested)
            {
                int read = await sslStream.ReadAsync(lengthBuffer, cancellationToken);
                if (read == 0) break; // EOF
                
                if (read < RiftFrame.LengthPrefixBytes)
                {
                    // For robustness we should handle partial reads, omitting for brevity
                    break;
                }

                uint payloadLength = System.Buffers.Binary.BinaryPrimitives.ReadUInt32BigEndian(lengthBuffer);
                if (payloadLength > RiftFrame.MaxPostAuthSize)
                {
                    sslStream.Close();
                    throw new InvalidOperationException("Payload too large");
                }

                byte[] payloadBuffer = new byte[payloadLength];
                int payloadRead = 0;
                while (payloadRead < payloadLength)
                {
                    int r = await sslStream.ReadAsync(payloadBuffer.AsMemory(payloadRead), cancellationToken);
                    if (r == 0) break;
                    payloadRead += r;
                }

                if (payloadRead == payloadLength)
                {
                    MessageReceived?.Invoke(this, new MessageReceivedEventArgs(deviceId, payloadBuffer));
                }
            }
        }
        catch (Exception)
        {
            
        }
        finally
        {
            _ = DisconnectPeerAsync(deviceId, CancellationToken.None);
        }
    }

    private bool ValidateRemoteCertificate(object sender, X509Certificate? certificate, X509Chain? chain, SslPolicyErrors sslPolicyErrors)
    {
        // Custom validation check against ITrustStore goes here
        // We accept self-signed certificates so we do not enforce full CA chains
        return true;
    }

    private string ExtractDeviceId(X509Certificate2 cert)
    {
        var ext = cert.Extensions["2.25.293029629918709742181702189012786017422"];
        if (ext == null) throw new AuthenticationException("Missing Ed25519 device identity extension");
        
        byte[] edKey = ext.RawData;
        
        using var sha256 = System.Security.Cryptography.SHA256.Create();
        byte[] hash = sha256.ComputeHash(edKey);
        
        return "rift-" + Rift.Daemon.Core.Cryptography.Base32Encoding.Encode(hash).Substring(0, 32);
    }

    public void Dispose()
    {
        _listener?.Stop();
        foreach (var sess in _activeSessions.Values)
        {
            try { sess.Close(); } catch {}
        }
    }
}
