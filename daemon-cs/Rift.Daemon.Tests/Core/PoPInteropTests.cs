using System;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using Xunit;

namespace Rift.Daemon.Tests.Core;

public class PoPInteropTests
{
    [Fact]
    public void AppNonceChannelBinding_MatchesVector()
    {
        var signerNonce = CreateRepeatedBytes(0x01, 32);
        var signerCertDer = Convert.FromHexString("aabbccdd");
        var verifierCertDer = Convert.FromHexString("eeff0011");

        using var sha256 = SHA256.Create();
        using var ms = new MemoryStream();
        ms.Write(signerNonce);
        ms.Write(signerCertDer);
        ms.Write(verifierCertDer);
        var channelBinding = sha256.ComputeHash(ms.ToArray());

        var hex = Convert.ToHexString(channelBinding).ToLowerInvariant();
        Assert.Equal("c27ec22512ef4f08cbb55cca019d1eb26d09ad24efeaff2626e56f6cb3afca36", hex);
    }

    [Fact]
    public void CertHash_MatchesVector()
    {
        var signerCertDer = Convert.FromHexString("aabbccdd");

        using var sha256 = SHA256.Create();
        var certHash = sha256.ComputeHash(signerCertDer);

        var hex = Convert.ToHexString(certHash).ToLowerInvariant();
        Assert.Equal("8d70d691c822d55638b6e7fd54cd94170c87d19eb1f628b757506ede5688d297", hex);
    }

    [Fact]
    public void SigningInput_MatchesVector_107Bytes_RawConcatenation()
    {
        var signerNonce = CreateRepeatedBytes(0x01, 32);
        var signerCertDer = Convert.FromHexString("aabbccdd");
        var verifierCertDer = Convert.FromHexString("eeff0011");
        var ed25519PubKey = Convert.FromHexString("d75a980182b10ab7d54bfed3c964073a0ee172f3daa3f4a18446b0b8d183f8e3");

        using var sha256 = SHA256.Create();

        using var cbMs = new MemoryStream();
        cbMs.Write(signerNonce);
        cbMs.Write(signerCertDer);
        cbMs.Write(verifierCertDer);
        var channelBinding = sha256.ComputeHash(cbMs.ToArray());

        var certHash = sha256.ComputeHash(signerCertDer);

        var prefix = Encoding.ASCII.GetBytes("RiftPoP-v2:");

        using var ms = new MemoryStream();
        ms.Write(prefix);
        ms.Write(channelBinding);
        ms.Write(ed25519PubKey);
        ms.Write(certHash);
        var signingInput = ms.ToArray();

        Assert.Equal(107, signingInput.Length);

        var hex = Convert.ToHexString(signingInput).ToLowerInvariant();
        Assert.Equal(
            "52696674506f502d76323ac27ec22512ef4f08cbb55cca019d1eb26d09ad24efeaff2626e56f6cb3afca36d75a980182b10ab7d54bfed3c964073a0ee172f3daa3f4a18446b0b8d183f8e38d70d691c822d55638b6e7fd54cd94170c87d19eb1f628b757506ede5688d297",
            hex);
    }

    private static byte[] CreateRepeatedBytes(byte value, int count)
    {
        var result = new byte[count];
        Array.Fill(result, value);
        return result;
    }
}
