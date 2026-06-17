using System;
using System.IO;
using System.Net.Security;
using System.Runtime.InteropServices;
using System.Security.Authentication.ExtendedProtection;
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
        var channelBinding = GetIdentityProofChannelBinding(sslStream);

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
        var channelBinding = GetIdentityProofChannelBinding(sslStream);

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

    protected virtual byte[] GetIdentityProofChannelBinding(SslStream sslStream)
    {
        ArgumentNullException.ThrowIfNull(sslStream);

        try
        {
            // TODO: Replace tls-unique with RFC 9266 tls-exporter once SslStream exposes exporter access
            // and we can verify the TLS 1.2 EMS requirement from spec §5.3.4. Until then, fail closed
            // if ChannelBindingKind.Unique is unavailable instead of silently signing a replayable proof.
            var binding = sslStream.TransportContext?.GetChannelBinding(ChannelBindingKind.Unique);
            if (binding is null)
            {
                throw new InvalidOperationException(
                    "TLS channel binding is unavailable; refusing to generate or verify identity proof without session binding.");
            }

            try
            {
                if (binding.Size <= 0)
                {
                    throw new InvalidOperationException(
                        $"TLS channel binding was empty or invalid ({binding.Size} bytes).");
                }

                // ChannelBindingKind.Unique can vary by negotiated TLS version/runtime.
                // TODO: Replace this fallback with spec-aligned tls-exporter handling and
                // explicit TLS 1.2 EMS enforcement once SslStream exposes exporter access.
                var channelBinding = new byte[binding.Size];
                Marshal.Copy(binding.DangerousGetHandle(), channelBinding, 0, channelBinding.Length);
                return channelBinding;
            }
            finally
            {
                binding.Dispose();
            }
        }
        catch (Exception ex) when (ex is NotSupportedException or PlatformNotSupportedException)
        {
            throw new InvalidOperationException(
                "TLS channel binding is not supported on this platform/runtime; refusing to generate or verify identity proof without session binding.",
                ex);
        }
    }

    /// <summary>
    /// Sends a session.hello message
    /// </summary>
    public async Task SendSessionHelloAsync(SslStream stream, CancellationToken cancellationToken)
    {
        await SendSessionControlMessageAsync(stream, "session.hello", cancellationToken);
    }

    /// <summary>
    /// Sends a session.accept message after successful peer identity verification.
    /// </summary>
    public async Task SendSessionAcceptAsync(SslStream stream, CancellationToken cancellationToken)
    {
        await SendSessionControlMessageAsync(stream, "session.accept", cancellationToken);
    }

    private async Task SendSessionControlMessageAsync(SslStream stream, string messageType, CancellationToken cancellationToken)
    {
        // For MVP, we will construct the JSON payload.
        // A complete implementation would map these to strong types per the IPC schema.
        var myDeviceId = _identityManager.GetDeviceId();
        var myEdKey = _identityManager.GetEd25519PublicKey();
        var myCert = _identityManager.GetTlsCertificate();

        var identityProof = GenerateIdentityProof(stream, myEdKey, myCert);
        var hexProof = BitConverter.ToString(identityProof).Replace("-", "").ToLowerInvariant();

        var capabilities = new[] {
            new { name = "clipboard.offer_fetch", version = 1 },
            new { name = "presence.basic", version = 1 },
            new { name = "operation.lifecycle", version = 1 },
            new { name = "security.event_log", version = 1 }
        };

        object payload = messageType switch
        {
            "session.hello" => new
            {
                supportedVersions = new[] { "0.1-draft" },
                deviceId = myDeviceId,
                implementationId = "riftd-cs/0.1.0",
                capabilities,
                identityProof = hexProof
            },
            "session.accept" => new
            {
                selectedVersion = "0.1-draft",
                deviceId = myDeviceId,
                identityVerified = true,
                identityProof = hexProof,
                capabilities
            },
            _ => throw new InvalidOperationException($"Unsupported session control message type '{messageType}'.")
        };

        var envelope = new
        {
            rift = "0.1-draft",
            type = messageType,
            messageId = Guid.NewGuid().ToString("D"),
            sourceDeviceId = myDeviceId,
            payload = payload
        };

        var json = JsonSerializer.Serialize(envelope);
        var frame = RiftFrame.Encode(Encoding.UTF8.GetBytes(json));

        await stream.WriteAsync(frame, cancellationToken);
    }
}
