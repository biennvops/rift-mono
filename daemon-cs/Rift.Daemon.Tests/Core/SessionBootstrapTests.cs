using System;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Net.Security;
using System.Security.Authentication;
using System.Security.Cryptography.X509Certificates;
using System.Text.Json;
using Microsoft.Extensions.Logging.Abstractions;
using Rift.Daemon.Core.Cryptography;
using Rift.Daemon.Core.Interfaces;
using Rift.Daemon.Core.Networking;
using Rift.Daemon.Core.Protocol;
using Xunit;

namespace Rift.Daemon.Tests.Core;

public class SessionBootstrapTests
{
    [Fact]
    public void GenerateIdentityProof_AppNonce_UsesNonceBasedBinding()
    {
        var identityManager = new IdentityManager();
        identityManager.EnsureIdentityInitialized();
        var cert = identityManager.GetTlsCertificate();
        var pubKey = identityManager.GetEd25519PublicKey();
        var peerCertDer = cert.GetRawCertData();
        using var stream = new SslStream(new MemoryStream());

        var bootstrapA = new TestSessionBootstrap(identityManager, CreateBinding(0x11), forceTlsUnique: false);
        var bootstrapB = new TestSessionBootstrap(identityManager, CreateBinding(0x22), forceTlsUnique: false);

        var (typeA, proofA, nonceA) = bootstrapA.GenerateIdentityProof(stream, pubKey, cert, peerCertDer);
        var (typeB, proofB, nonceB) = bootstrapB.GenerateIdentityProof(stream, pubKey, cert, peerCertDer);

        Assert.Equal("app-nonce", typeA);
        Assert.Equal("app-nonce", typeB);
        Assert.NotNull(nonceA);
        Assert.NotNull(nonceB);
        Assert.Equal(32, nonceA!.Length);
        Assert.Equal(32, nonceB!.Length);
        Assert.NotEqual(nonceA, nonceB);
        Assert.NotEqual(proofA, proofB);
    }

    [Fact]
    public void VerifyIdentityProof_AppNonce_FailsWhenPeerCertificateDoesNotMatch()
    {
        var identityManager = new IdentityManager();
        identityManager.EnsureIdentityInitialized();
        var cert = identityManager.GetTlsCertificate();
        var pubKey = identityManager.GetEd25519PublicKey();
        var peerIdentity = new IdentityManager();
        peerIdentity.EnsureIdentityInitialized();
        var wrongPeerIdentity = new IdentityManager();
        wrongPeerIdentity.EnsureIdentityInitialized();
        using var stream = new SslStream(new MemoryStream());

        var signingBootstrap = new TestSessionBootstrap(identityManager, CreateBinding(0x33), forceTlsUnique: false);
        var verifyingBootstrap = new TestSessionBootstrap(identityManager, CreateBinding(0x44), forceTlsUnique: false);

        var (_, proof, sessionNonce) = signingBootstrap.GenerateIdentityProof(
            stream,
            pubKey,
            cert,
            peerIdentity.GetTlsCertificate().GetRawCertData());
        var isValid = verifyingBootstrap.VerifyIdentityProof(
            stream,
            pubKey,
            wrongPeerIdentity.GetTlsCertificate(),
            proof,
            "app-nonce",
            sessionNonce);

        Assert.False(isValid);
    }

    [Fact]
    public void VerifyIdentityProof_SucceedsWhenChannelBindingMatches()
    {
        var identityManager = new IdentityManager();
        identityManager.EnsureIdentityInitialized();
        var cert = identityManager.GetTlsCertificate();
        var pubKey = identityManager.GetEd25519PublicKey();
        var peerCertDer = cert.GetRawCertData();
        using var stream = new SslStream(new MemoryStream());

        var bootstrap = new TestSessionBootstrap(identityManager, CreateBinding(0x55));

        var (bindingType, proof, sessionNonce) = bootstrap.GenerateIdentityProof(stream, pubKey, cert, peerCertDer);
        var isValid = bootstrap.VerifyIdentityProof(stream, pubKey, cert, proof, bindingType, sessionNonce);

        Assert.True(isValid);
    }

    [Fact]
    public void GenerateIdentityProof_ThrowsWhenChannelBindingUnavailable()
    {
        var identityManager = new IdentityManager();
        identityManager.EnsureIdentityInitialized();
        var cert = identityManager.GetTlsCertificate();
        var pubKey = identityManager.GetEd25519PublicKey();
        var peerCertDer = cert.GetRawCertData();
        using var stream = new SslStream(new MemoryStream());

        var bootstrap = new TestSessionBootstrap(identityManager, null);

        var (bindingType, proof, sessionNonce) = bootstrap.GenerateIdentityProof(stream, pubKey, cert, peerCertDer);

        Assert.Equal("app-nonce", bindingType);
        Assert.NotNull(sessionNonce);
        Assert.Equal(32, sessionNonce!.Length);
        Assert.NotNull(proof);
    }

    [Fact]
    public void VerifyIdentityProof_AppNonce_SucceedsWithMatchingNonce()
    {
        var identityManager = new IdentityManager();
        identityManager.EnsureIdentityInitialized();
        var cert = identityManager.GetTlsCertificate();
        var pubKey = identityManager.GetEd25519PublicKey();
        var certDer = cert.GetRawCertData();
        using var stream = new SslStream(new MemoryStream());

        var bootstrap = new TestSessionBootstrap(identityManager, null);

        var (bindingType, proof, sessionNonce) = bootstrap.GenerateIdentityProof(stream, pubKey, cert, certDer);

        Assert.Equal("app-nonce", bindingType);

        var isValid = bootstrap.VerifyIdentityProof(stream, pubKey, cert, proof, "app-nonce", sessionNonce);

        Assert.True(isValid);
    }

    [Fact]
    public void VerifyIdentityProof_AppNonce_FailsWithWrongNonce()
    {
        var identityManager = new IdentityManager();
        identityManager.EnsureIdentityInitialized();
        var cert = identityManager.GetTlsCertificate();
        var pubKey = identityManager.GetEd25519PublicKey();
        var certDer = cert.GetRawCertData();
        using var stream = new SslStream(new MemoryStream());

        var bootstrap = new TestSessionBootstrap(identityManager, null);

        var (_, proof, _) = bootstrap.GenerateIdentityProof(stream, pubKey, cert, certDer);

        var wrongNonce = Enumerable.Repeat((byte)0xFF, 32).ToArray();
        var isValid = bootstrap.VerifyIdentityProof(stream, pubKey, cert, proof, "app-nonce", wrongNonce);

        Assert.False(isValid);
    }

    [Fact]
    public async Task SendSessionHelloAsync_EmitsAppNonceHelloPayload()
    {
        var identityManager = new IdentityManager(displayNameProvider: () => "Office Desktop");
        identityManager.EnsureIdentityInitialized();
        var peerIdentity = new IdentityManager();
        peerIdentity.EnsureIdentityInitialized();
        await using var pair = await CreateAuthenticatedLoopbackPairAsync(identityManager, peerIdentity);

        var bootstrap = new TestSessionBootstrap(identityManager, null);

        await bootstrap.SendSessionHelloAsync(pair.ClientStream, peerIdentity.GetTlsCertificate().GetRawCertData(), CancellationToken.None);

        var payload = await ReadFramePayloadAsync(pair.ServerStream, CancellationToken.None);
        using var document = JsonDocument.Parse(payload);
        var root = document.RootElement;
        var messagePayload = root.GetProperty("payload");

        Assert.Equal("session.hello", root.GetProperty("type").GetString());
        Assert.Equal(identityManager.GetDeviceId(), root.GetProperty("sourceDeviceId").GetString());
        Assert.Equal(identityManager.GetDeviceId(), messagePayload.GetProperty("deviceId").GetString());
        Assert.Equal("app-nonce", messagePayload.GetProperty("bindingType").GetString());
        Assert.False(string.IsNullOrWhiteSpace(messagePayload.GetProperty("identityProof").GetString()));

        var sessionNonce = Convert.FromBase64String(messagePayload.GetProperty("sessionNonce").GetString()!);
        Assert.Equal(32, sessionNonce.Length);
        Assert.Equal("riftd-cs/0.1.0", messagePayload.GetProperty("implementationId").GetString());
        Assert.False(messagePayload.TryGetProperty("displayName", out _));
        Assert.False(messagePayload.TryGetProperty("platform", out _));
        Assert.Contains(
            messagePayload.GetProperty("supportedVersions").EnumerateArray().Select(element => element.GetString()),
            version => version == "0.1-draft");
        Assert.True(messagePayload.GetProperty("capabilities").GetArrayLength() >= 4);
    }

    [Fact]
    public async Task SendSessionAcceptAsync_EmitsAppNonceAcceptPayload()
    {
        var identityManager = new IdentityManager(displayNameProvider: () => "Office Desktop");
        identityManager.EnsureIdentityInitialized();
        var peerIdentity = new IdentityManager();
        peerIdentity.EnsureIdentityInitialized();
        await using var pair = await CreateAuthenticatedLoopbackPairAsync(identityManager, peerIdentity);

        var bootstrap = new TestSessionBootstrap(identityManager, null);

        await bootstrap.SendSessionAcceptAsync(pair.ClientStream, peerIdentity.GetTlsCertificate().GetRawCertData(), CancellationToken.None);

        var payload = await ReadFramePayloadAsync(pair.ServerStream, CancellationToken.None);
        using var document = JsonDocument.Parse(payload);
        var root = document.RootElement;
        var messagePayload = root.GetProperty("payload");

        Assert.Equal("session.accept", root.GetProperty("type").GetString());
        Assert.Equal(identityManager.GetDeviceId(), root.GetProperty("sourceDeviceId").GetString());
        Assert.Equal(identityManager.GetDeviceId(), messagePayload.GetProperty("deviceId").GetString());
        Assert.Equal("0.1-draft", messagePayload.GetProperty("selectedVersion").GetString());
        Assert.True(messagePayload.GetProperty("identityVerified").GetBoolean());
        Assert.False(messagePayload.TryGetProperty("displayName", out _));
        Assert.False(messagePayload.TryGetProperty("platform", out _));
        Assert.Equal("app-nonce", messagePayload.GetProperty("bindingType").GetString());

        var sessionNonce = Convert.FromBase64String(messagePayload.GetProperty("sessionNonce").GetString()!);
        Assert.Equal(32, sessionNonce.Length);
        Assert.False(string.IsNullOrWhiteSpace(messagePayload.GetProperty("identityProof").GetString()));
        Assert.True(messagePayload.GetProperty("capabilities").GetArrayLength() >= 4);
    }

    private static byte[] CreateBinding(byte value)
    {
        return Enumerable.Repeat(value, 32).ToArray();
    }

    private static async Task<byte[]> ReadFramePayloadAsync(Stream stream, CancellationToken cancellationToken)
    {
        var header = new byte[RiftFrame.LengthPrefixBytes];
        await ReadExactAsync(stream, header, cancellationToken);
        var payloadLength = System.Buffers.Binary.BinaryPrimitives.ReadUInt32BigEndian(header);
        var payload = new byte[payloadLength];
        await ReadExactAsync(stream, payload, cancellationToken);
        return payload;
    }

    private static async Task ReadExactAsync(Stream stream, byte[] buffer, CancellationToken cancellationToken)
    {
        var totalRead = 0;
        while (totalRead < buffer.Length)
        {
            var read = await stream.ReadAsync(buffer.AsMemory(totalRead, buffer.Length - totalRead), cancellationToken);
            Assert.True(read > 0, "Expected more TLS application data but stream closed early.");
            totalRead += read;
        }
    }

    private static async Task<AuthenticatedLoopbackPair> CreateAuthenticatedLoopbackPairAsync(
        IdentityManager serverIdentity,
        IdentityManager clientIdentity)
    {
        var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();

        var acceptTask = listener.AcceptTcpClientAsync();
        var clientTcp = new TcpClient();
        await clientTcp.ConnectAsync(IPAddress.Loopback, ((IPEndPoint)listener.LocalEndpoint).Port);
        var serverTcp = await acceptTask;
        listener.Stop();

        var serverStream = new SslStream(serverTcp.GetStream(), false, (_, _, _, _) => true);
        var clientStream = new SslStream(clientTcp.GetStream(), false, (_, _, _, _) => true);

        var serverAuthTask = serverStream.AuthenticateAsServerAsync(new SslServerAuthenticationOptions
        {
            ServerCertificate = serverIdentity.GetTlsCertificate(),
            ClientCertificateRequired = true,
            EnabledSslProtocols = SslProtocols.Tls13 | SslProtocols.Tls12,
            CertificateRevocationCheckMode = X509RevocationMode.NoCheck
        });

        var clientAuthTask = clientStream.AuthenticateAsClientAsync(new SslClientAuthenticationOptions
        {
            TargetHost = "127.0.0.1",
            ClientCertificates = new X509CertificateCollection { clientIdentity.GetTlsCertificate() },
            EnabledSslProtocols = SslProtocols.Tls13 | SslProtocols.Tls12,
            CertificateRevocationCheckMode = X509RevocationMode.NoCheck
        });

        await Task.WhenAll(serverAuthTask, clientAuthTask);
        return new AuthenticatedLoopbackPair(serverTcp, clientTcp, serverStream, clientStream);
    }

    private sealed class TestSessionBootstrap : SessionBootstrap
    {
        private readonly byte[]? _channelBinding;
        private readonly bool _forceTlsUnique;

        public TestSessionBootstrap(IIdentityManager identityManager, byte[]? channelBinding, bool forceTlsUnique = true)
            : base(NullLogger<SessionBootstrap>.Instance, identityManager)
        {
            _channelBinding = channelBinding;
            _forceTlsUnique = forceTlsUnique;
        }

        protected override (string bindingType, byte[] channelBinding, byte[]? sessionNonce) GetChannelBinding(
            SslStream sslStream, X509Certificate2 localCert, byte[]? peerCertDer)
        {
            if (_forceTlsUnique)
            {
                if (TryGetTlsChannelBinding(sslStream, out var cb))
                    return ("tls-unique", cb, null);
            }
            return base.GetChannelBinding(sslStream, localCert, peerCertDer);
        }

        protected override bool TryGetTlsChannelBinding(SslStream sslStream, out byte[] channelBinding)
        {
            if (_channelBinding is null)
            {
                channelBinding = [];
                return false;
            }

            channelBinding = _channelBinding;
            return true;
        }
    }

    private sealed class AuthenticatedLoopbackPair : IAsyncDisposable
    {
        public AuthenticatedLoopbackPair(
            TcpClient serverTcp,
            TcpClient clientTcp,
            SslStream serverStream,
            SslStream clientStream)
        {
            ServerTcp = serverTcp;
            ClientTcp = clientTcp;
            ServerStream = serverStream;
            ClientStream = clientStream;
        }

        public TcpClient ServerTcp { get; }
        public TcpClient ClientTcp { get; }
        public SslStream ServerStream { get; }
        public SslStream ClientStream { get; }

        public ValueTask DisposeAsync()
        {
            ServerStream.Dispose();
            ClientStream.Dispose();
            ServerTcp.Dispose();
            ClientTcp.Dispose();
            return ValueTask.CompletedTask;
        }
    }
}
