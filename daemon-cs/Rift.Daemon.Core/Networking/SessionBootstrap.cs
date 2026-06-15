using System;
using System.IO;
using System.Net.Security;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Extensions.Logging;
using Rift.Daemon.Core.Cryptography;
using Rift.Daemon.Core.Interfaces;
using Rift.Daemon.Core.Protocol;

namespace Rift.Daemon.Core.Networking;

public class SessionBootstrap
{
    private readonly ILogger<SessionBootstrap> _logger;
    private readonly IIdentityManager _identityManager;

    public SessionBootstrap(ILogger<SessionBootstrap> logger, IIdentityManager identityManager)
    {
        _logger = logger;
        _identityManager = identityManager;
    }

    /// <summary>
    /// Generates identityProof used in session.hello and session.accept (Spec §5.3)
    /// </summary>
    public byte[] GenerateIdentityProof(SslStream sslStream, byte[] myEd25519PubKey, X509Certificate2 myCert)
    {
        // ExportTlsSecret is not exposed natively by SslStream in this framework version.
        // Using dummy binding for MVP.
        byte[] channelBinding = new byte[32];

        using var sha256 = SHA256.Create();
        var certHash = sha256.ComputeHash(myCert.GetRawCertData());

        var prefixInfo = Encoding.ASCII.GetBytes("RiftPoP-v2:");
        
        using var ms = new MemoryStream();
        ms.Write(prefixInfo);
        ms.Write(channelBinding);
        ms.Write(myEd25519PubKey);
        ms.Write(certHash);
        
        var signingInput = ms.ToArray();

        return _identityManager.SignEd25519(signingInput);
    }

    /// <summary>
    /// Verifies the identityProof received from a peer (Spec §5.3)
    /// </summary>
    public bool VerifyIdentityProof(SslStream sslStream, byte[] peerEd25519PubKey, X509Certificate2 peerCert, byte[] signatureBytes)
    {
        // ExportTlsSecret is not exposed natively. Using dummy binding for MVP.
        byte[] channelBinding = new byte[32];

        using var sha256 = SHA256.Create();
        var certHash = sha256.ComputeHash(peerCert.GetRawCertData());

        var prefixInfo = Encoding.ASCII.GetBytes("RiftPoP-v2:");
        
        using var ms = new MemoryStream();
        ms.Write(prefixInfo);
        ms.Write(channelBinding);
        ms.Write(peerEd25519PubKey);
        ms.Write(certHash);
        
        var expectedInput = ms.ToArray();

        return _identityManager.VerifyEd25519(peerEd25519PubKey, expectedInput, signatureBytes);
    }

    /// <summary>
    /// Sends a session.hello message
    /// </summary>
    public async Task SendSessionHelloAsync(SslStream stream, string peerDeviceId, CancellationToken cancellationToken)
    {
        // For MVP, we will construct the JSON payload.
        // A complete implementation would map these to strong types per the IPC schema.
        var myDeviceId = _identityManager.GetDeviceId();
        var myEdKey = _identityManager.GetEd25519PublicKey();
        var myCert = _identityManager.GetTlsCertificate();

        var identityProof = GenerateIdentityProof(stream, myEdKey, myCert);
        var hexProof = BitConverter.ToString(identityProof).Replace("-", "").ToLowerInvariant();

        var payload = new
        {
            supportedVersions = new[] { "0.1-draft" },
            deviceId = myDeviceId,
            implementationId = "riftd-cs/0.1.0",
            capabilities = new[] {
                new { name = "clipboard.offer_fetch", version = 1 },
                new { name = "presence.basic", version = 1 },
                new { name = "operation.lifecycle", version = 1 },
                new { name = "security.event_log", version = 1 }
            },
            identityProof = hexProof
        };

        var envelope = new
        {
            rift = "0.1-draft",
            type = "session.hello",
            messageId = Guid.NewGuid().ToString("D"),
            sourceDeviceId = myDeviceId,
            payload = payload
        };

        var json = JsonSerializer.Serialize(envelope);
        var frame = RiftFrame.Encode(Encoding.UTF8.GetBytes(json));

        await stream.WriteAsync(frame, cancellationToken);
    }
}
