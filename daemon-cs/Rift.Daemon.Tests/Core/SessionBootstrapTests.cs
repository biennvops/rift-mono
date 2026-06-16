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
    public void GenerateIdentityProof_ChangesWhenChannelBindingChanges()
    {
        var identityManager = new IdentityManager();
        identityManager.EnsureIdentityInitialized();
        var cert = identityManager.GetTlsCertificate();
        var pubKey = identityManager.GetEd25519PublicKey();
        using var stream = new SslStream(new MemoryStream());

        var bootstrapA = new TestSessionBootstrap(identityManager, CreateBinding(0x11));
        var bootstrapB = new TestSessionBootstrap(identityManager, CreateBinding(0x22));

        var proofA = bootstrapA.GenerateIdentityProof(stream, pubKey, cert);
        var proofB = bootstrapB.GenerateIdentityProof(stream, pubKey, cert);

        Assert.NotEqual(proofA, proofB);
    }

    [Fact]
    public void VerifyIdentityProof_FailsWhenChannelBindingDoesNotMatch()
    {
        var identityManager = new IdentityManager();
        identityManager.EnsureIdentityInitialized();
        var cert = identityManager.GetTlsCertificate();
        var pubKey = identityManager.GetEd25519PublicKey();
        using var stream = new SslStream(new MemoryStream());

        var signingBootstrap = new TestSessionBootstrap(identityManager, CreateBinding(0x33));
        var verifyingBootstrap = new TestSessionBootstrap(identityManager, CreateBinding(0x44));

        var proof = signingBootstrap.GenerateIdentityProof(stream, pubKey, cert);
        var isValid = verifyingBootstrap.VerifyIdentityProof(stream, pubKey, cert, proof);

        Assert.False(isValid);
    }

    [Fact]
    public void GenerateIdentityProof_ThrowsWhenChannelBindingUnavailable()
    {
        var identityManager = new IdentityManager();
        identityManager.EnsureIdentityInitialized();
        var cert = identityManager.GetTlsCertificate();
        var pubKey = identityManager.GetEd25519PublicKey();
        using var stream = new SslStream(new MemoryStream());

        var bootstrap = new TestSessionBootstrap(identityManager, null);

        var ex = Assert.Throws<InvalidOperationException>(() => bootstrap.GenerateIdentityProof(stream, pubKey, cert));
        Assert.Contains("channel binding", ex.Message, StringComparison.OrdinalIgnoreCase);
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

        protected override byte[] GetIdentityProofChannelBinding(SslStream sslStream)
        {
            if (_channelBinding is null)
            {
                throw new InvalidOperationException("TLS channel binding is unavailable in test.");
            }

            return _channelBinding;
        }
    }
}
