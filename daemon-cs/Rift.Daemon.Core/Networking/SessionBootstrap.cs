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
using Rift.Daemon.Core.Interfaces;
using Rift.Daemon.Core.Protocol;

namespace Rift.Daemon.Core.Networking;

public class SessionBootstrap(
    IIdentityManager identityManager,
    ILogger<SessionBootstrap> logger)
{
    private const string PopLabel = "EXPORTER-RIFT-Ed25519-PoP";

    public async Task<bool> AuthenticateSessionAsync(SslStream stream, string peerDeviceId, bool isClient, CancellationToken ct)
    {
        try
        {
            if (isClient)
            {
                return await RunClientBootstrapAsync(stream, peerDeviceId, ct);
            }
            else
            {
                return await RunServerBootstrapAsync(stream, peerDeviceId, ct);
            }
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Bootstrap failed for peer {PeerDeviceId}", peerDeviceId);
            return false;
        }
    }

    private async Task<bool> RunClientBootstrapAsync(SslStream stream, string peerDeviceId, CancellationToken ct)
    {
        // 1. Send session.hello
        var hello = new SessionHelloPayload
        {
            DeviceId = identityManager.GetDeviceId(),
            ImplementationId = "riftd-cs/0.1.0",
            IdentityProof = CreatePoP(stream)
        };
        
        await SendMessageAsync(stream, "session.hello", hello, ct);

        // 2. Wait for session.accept
        var response = await ReceiveMessageAsync(stream, ct);
        if (response?.Type != "session.accept")
        {
            logger.LogWarning("Expected session.accept, got {Type}", response?.Type);
            return false;
        }

        var accept = JsonSerializer.Deserialize<SessionAcceptPayload>(response.Payload.ToString()!)!;
        
        // 3. Verify Peer PoP
        return VerifyPoP(stream, peerDeviceId, accept.IdentityProof);
    }

    private async Task<bool> RunServerBootstrapAsync(SslStream stream, string peerDeviceId, CancellationToken ct)
    {
        // 1. Wait for session.hello
        var request = await ReceiveMessageAsync(stream, ct);
        if (request?.Type != "session.hello")
        {
            logger.LogWarning("Expected session.hello, got {Type}", request?.Type);
            return false;
        }

        var hello = JsonSerializer.Deserialize<SessionHelloPayload>(request.Payload.ToString()!)!;

        // 2. Verify Peer PoP
        if (!VerifyPoP(stream, peerDeviceId, hello.IdentityProof))
        {
            return false;
        }

        // 3. Send session.accept
        var accept = new SessionAcceptPayload
        {
            DeviceId = identityManager.GetDeviceId(),
            IdentityProof = CreatePoP(stream)
        };

        await SendMessageAsync(stream, "session.accept", accept, ct);
        return true;
    }

    private string CreatePoP(SslStream stream)
    {
        // Spec §5.3.1: Proof Construction
        byte[] channelBinding = stream.GetTlsExporterValue(PopLabel, null);
        
        var myCert = identityManager.GetTlsCertificate();
        byte[] certHash = SHA256.HashData(myCert.RawData);
        byte[] myPublicKey = identityManager.GetEd25519PublicKey();

        // RiftPoP-v2: + 32-byte binding + 32-byte public key + 32-byte cert hash
        byte[] prefix = Encoding.ASCII.GetBytes("RiftPoP-v2:");
        byte[] input = new byte[prefix.Length + 32 + 32 + 32];
        
        Buffer.BlockCopy(prefix, 0, input, 0, prefix.Length);
        Buffer.BlockCopy(channelBinding, 0, input, prefix.Length, 32);
        Buffer.BlockCopy(myPublicKey, 0, input, prefix.Length + 32, 32);
        Buffer.BlockCopy(certHash, 0, input, prefix.Length + 64, 32);

        byte[] signature = identityManager.SignEd25519(input);
        return Convert.ToHexString(signature).ToLower();
    }

    private bool VerifyPoP(SslStream stream, string peerDeviceId, string proofHex)
    {
        try
        {
            byte[] proof = Convert.FromHexString(proofHex);
            byte[] channelBinding = stream.GetTlsExporterValue(PopLabel, null);

            var peerCert = (X509Certificate2)stream.RemoteCertificate!;
            byte[] certHash = SHA256.HashData(peerCert.RawData);
            
            // We MUST use the public key from the certificate extension
            // (extratced in TlsTransport but we re-extract here or pass it)
            // For now, we'll re-extract from the remote certificate.
            byte[]? peerPublicKey = ExtractEd25519PublicKey(peerCert);
            if (peerPublicKey == null) return false;

            byte[] prefix = Encoding.ASCII.GetBytes("RiftPoP-v2:");
            byte[] input = new byte[prefix.Length + 32 + 32 + 32];
            
            Buffer.BlockCopy(prefix, 0, input, 0, prefix.Length);
            Buffer.BlockCopy(channelBinding, 0, input, prefix.Length, 32);
            Buffer.BlockCopy(peerPublicKey, 0, input, prefix.Length + 32, 32);
            Buffer.BlockCopy(certHash, 0, input, prefix.Length + 64, 32);

            // Verify signature
            var verifier = Org.BouncyCastle.Security.SignerUtilities.GetSigner("Ed25519");
            var pubKeyParams = new Org.BouncyCastle.Crypto.Parameters.Ed25519PublicKeyParameters(peerPublicKey, 0);
            verifier.Init(false, pubKeyParams);
            verifier.BlockUpdate(input, 0, input.Length);
            
            bool valid = verifier.VerifySignature(proof);
            if (!valid)
            {
                 logger.LogCritical("auth.identity_proof_failed: PoP verification failed for {PeerDeviceId}", peerDeviceId);
            }
            return valid;
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "PoP verification crashed for {PeerDeviceId}", peerDeviceId);
            return false;
        }
    }

    private byte[]? ExtractEd25519PublicKey(X509Certificate2 cert)
    {
        var extension = cert.Extensions.FirstOrDefault(e => e.Oid?.Value == "2.25.293029629918709742181702189012786017422");
        if (extension == null) return null;
        byte[] raw = extension.RawData;
        if (raw.Length != 36 || raw[0] != 0x04 || raw[1] != 34 || raw[2] != 0x04 || raw[3] != 32) return null;
        return raw.AsSpan(4, 32).ToArray();
    }

    private async Task SendMessageAsync(SslStream stream, string type, object payload, CancellationToken ct)
    {
        var envelope = new RiftMessageEnvelope
        {
            Type = type,
            SourceDeviceId = identityManager.GetDeviceId(),
            Payload = payload
        };
        
        byte[] json = JsonSerializer.SerializeToUtf8Bytes(envelope);
        byte[] framed = RiftFrame.Encode(json);
        await stream.WriteAsync(framed, ct);
        await stream.FlushAsync(ct);
    }

    private async Task<RiftMessageEnvelope?> ReceiveMessageAsync(SslStream stream, CancellationToken ct)
    {
        byte[] lenBuf = new byte[4];
        int read = await FullReadAsync(stream, lenBuf, ct);
        if (read < 4) return null;

        uint len = System.Buffers.Binary.BinaryPrimitives.ReadUInt32BigEndian(lenBuf);
        if (len > 64 * 1024) throw new InvalidOperationException("Bootstrap message too large");

        byte[] payload = new byte[len];
        read = await FullReadAsync(stream, payload, ct);
        if (read < len) return null;

        return JsonSerializer.Deserialize<RiftMessageEnvelope>(payload);
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
}
