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
    /// Generates identityProof used in session.hello and session.accept (Spec §5.3).
    /// Returns the binding type used and the signature bytes.
    /// </summary>
    public (string bindingType, byte[] signature, byte[]? sessionNonce) GenerateIdentityProof(
        SslStream sslStream, byte[] myEd25519PubKey, X509Certificate2 myCert, byte[]? peerCertDer = null)
    {
        var (bindingType, channelBinding, sessionNonce) = GetChannelBinding(sslStream, myCert, peerCertDer);

        using var sha256 = SHA256.Create();
        var certHash = sha256.ComputeHash(myCert.GetRawCertData());

        var prefixInfo = Encoding.ASCII.GetBytes("RiftPoP-v2:");

        using var ms = new MemoryStream();
        ms.Write(prefixInfo);
        ms.Write(channelBinding);
        ms.Write(myEd25519PubKey);
        ms.Write(certHash);

        var signingInput = ms.ToArray();

        return (bindingType, _identityManager.SignEd25519(signingInput), sessionNonce);
    }

    private static readonly string[] ValidBindingTypes = ["tls-exporter", "tls-unique", "app-nonce"];

    /// <summary>
    /// Verifies the identityProof received from a peer (Spec §5.3)
    /// </summary>
    public bool VerifyIdentityProof(SslStream sslStream, byte[] peerEd25519PubKey, X509Certificate2 peerCert,
        byte[] signatureBytes, string peerBindingType, byte[]? peerSessionNonce = null)
    {
        if (Array.IndexOf(ValidBindingTypes, peerBindingType) < 0)
            throw new InvalidOperationException($"Unrecognized bindingType: '{peerBindingType}'.");

        byte[] channelBinding;

        if (peerBindingType == "app-nonce")
        {
            if (peerSessionNonce is null || peerSessionNonce.Length != 32)
                throw new InvalidOperationException("app-nonce bindingType requires a 32-byte sessionNonce from the peer.");

            var localCert = _identityManager.GetTlsCertificate();
            channelBinding = ComputeAppNonceBinding(peerSessionNonce, peerCert.GetRawCertData(), localCert.GetRawCertData());
        }
        else if (peerBindingType == "tls-unique")
        {
            channelBinding = GetTlsChannelBinding(sslStream);
        }
        else
        {
            throw new InvalidOperationException(
                $"C# daemon does not yet support verifying bindingType '{peerBindingType}'. " +
                "tls-exporter requires SslStream.ExportKeyingMaterial (not yet available in .NET).");
        }

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

    private (string bindingType, byte[] channelBinding, byte[]? sessionNonce) GetChannelBinding(
        SslStream sslStream, X509Certificate2 localCert, byte[]? peerCertDer)
    {
        try
        {
            var tlsBinding = GetTlsChannelBinding(sslStream);
            return ("tls-unique", tlsBinding, null);
        }
        catch (InvalidOperationException ex) when (ex.Message.Contains("unavailable") || ex.Message.Contains("not supported"))
        {
            // TLS channel binding unavailable — fall back to Tier 3 (app-nonce).
        }

        if (peerCertDer is null)
            throw new InvalidOperationException(
                "Cannot compute app-nonce channel binding: peer certificate DER is required.");

        var sessionNonce = new byte[32];
        using var rng = RandomNumberGenerator.Create();
        rng.GetBytes(sessionNonce);

        var channelBinding = ComputeAppNonceBinding(sessionNonce, localCert.GetRawCertData(), peerCertDer);
        _logger.LogWarning("Using app-nonce channel binding (Tier 3) — tls-unique was unavailable.");
        return ("app-nonce", channelBinding, sessionNonce);
    }

    private static byte[] ComputeAppNonceBinding(byte[] signerNonce, byte[] signerCertDer, byte[] verifierCertDer)
    {
        using var sha256 = SHA256.Create();
        using var ms = new MemoryStream();
        ms.Write(signerNonce);
        ms.Write(signerCertDer);
        ms.Write(verifierCertDer);
        return sha256.ComputeHash(ms.ToArray());
    }

    protected virtual byte[] GetTlsChannelBinding(SslStream sslStream)
    {
        ArgumentNullException.ThrowIfNull(sslStream);

        try
        {
            var binding = sslStream.TransportContext?.GetChannelBinding(ChannelBindingKind.Unique);
            if (binding is null)
            {
                throw new InvalidOperationException(
                    "TLS channel binding is unavailable; falling back to app-nonce.");
            }

            try
            {
                if (binding.Size <= 0)
                {
                    throw new InvalidOperationException(
                        $"TLS channel binding was empty or invalid ({binding.Size} bytes).");
                }

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
                "TLS channel binding is not supported on this platform/runtime.",
                ex);
        }
    }

    /// <summary>
    /// Sends a session.hello message
    /// </summary>
    public async Task SendSessionHelloAsync(SslStream stream, byte[]? peerCertDer, CancellationToken cancellationToken)
    {
        await SendSessionControlMessageAsync(stream, "session.hello", peerCertDer, cancellationToken);
    }

    /// <summary>
    /// Sends a session.accept message after successful peer identity verification.
    /// </summary>
    public async Task SendSessionAcceptAsync(SslStream stream, byte[]? peerCertDer, CancellationToken cancellationToken)
    {
        await SendSessionControlMessageAsync(stream, "session.accept", peerCertDer, cancellationToken);
    }

    private async Task SendSessionControlMessageAsync(SslStream stream, string messageType,
        byte[]? peerCertDer, CancellationToken cancellationToken)
    {
        var myDeviceId = _identityManager.GetDeviceId();
        var myEdKey = _identityManager.GetEd25519PublicKey();
        var myCert = _identityManager.GetTlsCertificate();

        var (bindingType, identityProof, sessionNonce) = GenerateIdentityProof(stream, myEdKey, myCert, peerCertDer);
        var hexProof = BitConverter.ToString(identityProof).Replace("-", "").ToLowerInvariant();

        var capabilities = new[] {
            new { name = "clipboard.offer_fetch", version = 1 },
            new { name = "presence.basic", version = 1 },
            new { name = "operation.lifecycle", version = 1 },
            new { name = "security.event_log", version = 1 }
        };

        var nonceBase64 = sessionNonce is not null ? Convert.ToBase64String(sessionNonce) : null;

        object payload = messageType switch
        {
            "session.hello" => new
            {
                supportedVersions = new[] { "0.1-draft" },
                deviceId = myDeviceId,
                implementationId = "riftd-cs/0.1.0",
                capabilities,
                bindingType,
                sessionNonce = nonceBase64,
                identityProof = hexProof
            },
            "session.accept" => new
            {
                selectedVersion = "0.1-draft",
                deviceId = myDeviceId,
                identityVerified = true,
                bindingType,
                sessionNonce = nonceBase64,
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

        var json = JsonSerializer.Serialize(envelope, new JsonSerializerOptions
        {
            DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull
        });
        var frame = RiftFrame.Encode(Encoding.UTF8.GetBytes(json));

        await stream.WriteAsync(frame, cancellationToken);
    }
}
