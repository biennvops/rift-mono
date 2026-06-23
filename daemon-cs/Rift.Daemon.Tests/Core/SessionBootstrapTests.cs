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
    public void GenerateIdentityProof_TlsUnique_ChangesWhenChannelBindingChanges()
    {
        var identityManager = new IdentityManager();
        identityManager.EnsureIdentityInitialized();
        var cert = identityManager.GetTlsCertificate();
        var pubKey = identityManager.GetEd25519PublicKey();
        using var stream = new SslStream(new MemoryStream());

        var bootstrapA = new TestSessionBootstrap(identityManager, CreateBinding(0x11));
        var bootstrapB = new TestSessionBootstrap(identityManager, CreateBinding(0x22));

        var (typeA, proofA, nonceA) = bootstrapA.GenerateIdentityProof(stream, pubKey, cert);
        var (typeB, proofB, nonceB) = bootstrapB.GenerateIdentityProof(stream, pubKey, cert);

        Assert.Equal("tls-unique", typeA);
        Assert.Equal("tls-unique", typeB);
        Assert.Null(nonceA);
        Assert.Null(nonceB);
        Assert.NotEqual(proofA, proofB);
    }

    [Fact]
    public void VerifyIdentityProof_TlsUnique_FailsWhenChannelBindingDoesNotMatch()
    {
        var identityManager = new IdentityManager();
        identityManager.EnsureIdentityInitialized();
        var cert = identityManager.GetTlsCertificate();
        var pubKey = identityManager.GetEd25519PublicKey();
        using var stream = new SslStream(new MemoryStream());

        var signingBootstrap = new TestSessionBootstrap(identityManager, CreateBinding(0x33));
        var verifyingBootstrap = new TestSessionBootstrap(identityManager, CreateBinding(0x44));

        var (_, proof, _) = signingBootstrap.GenerateIdentityProof(stream, pubKey, cert);
        var isValid = verifyingBootstrap.VerifyIdentityProof(stream, pubKey, cert, proof, "tls-unique");

        Assert.False(isValid);
    }

    [Fact]
    public void VerifyIdentityProof_SucceedsWhenChannelBindingMatches()
    {
        var identityManager = new IdentityManager();
        identityManager.EnsureIdentityInitialized();
        var cert = identityManager.GetTlsCertificate();
        var pubKey = identityManager.GetEd25519PublicKey();
        using var stream = new SslStream(new MemoryStream());

        var bootstrap = new TestSessionBootstrap(identityManager, CreateBinding(0x55));

        var (bindingType, proof, sessionNonce) = bootstrap.GenerateIdentityProof(stream, pubKey, cert);
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
        var identityManager = new IdentityManager();
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
        Assert.Contains(
            messagePayload.GetProperty("supportedVersions").EnumerateArray().Select(element => element.GetString()),
            version => version == "0.1-draft");
        Assert.True(messagePayload.GetProperty("capabilities").GetArrayLength() >= 4);
    }

    [Fact]
    public async Task SendSessionAcceptAsync_EmitsAppNonceAcceptPayload()
    {
        var identityManager = new IdentityManager();
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

        public TestSessionBootstrap(IIdentityManager identityManager, byte[]? channelBinding)
            : base(NullLogger<SessionBootstrap>.Instance, identityManager)
        {
            _channelBinding = channelBinding;
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
