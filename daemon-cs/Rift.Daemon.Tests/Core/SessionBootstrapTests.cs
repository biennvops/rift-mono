using System;
using System.IO;
using System.Linq;
using System.Net.Security;
using Microsoft.Extensions.Logging.Abstractions;
using Rift.Daemon.Core.Cryptography;
using Rift.Daemon.Core.Interfaces;
using Rift.Daemon.Core.Networking;
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

        var proof = bootstrap.GenerateIdentityProof(stream, pubKey, cert);
        var isValid = bootstrap.VerifyIdentityProof(stream, pubKey, cert, proof);

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

    private static byte[] CreateBinding(byte value)
    {
        return Enumerable.Repeat(value, 32).ToArray();
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
}
