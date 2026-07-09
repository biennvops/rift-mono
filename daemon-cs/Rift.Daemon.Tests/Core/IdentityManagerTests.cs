using System;
using System.Linq;
using System.Security.Cryptography.X509Certificates;
using Xunit;
using Rift.Daemon.Core.Cryptography;

namespace Rift.Daemon.Tests.Core;

public class IdentityManagerTests
{
    // Test Vector from spec §15.1
    private static readonly byte[] TestPublicKey = Convert.FromHexString("d75a980182b10ab7d54bfed3c964073a0ee172f3daa3f4a18446b0b8d183f8e3");

    [Fact]
    public void Test_DeviceId_MatchesSpecVector()
    {
        var expectedDeviceId = "rift-cpgwo6wefdkxwxfugsvcjbwj6mhp4gfq";
        var actualDeviceId = IdentityManager.DeriveDeviceId(TestPublicKey);
        
        Assert.Equal(expectedDeviceId, actualDeviceId);
    }

    [Fact]
    public void Test_Fingerprint_MatchesSpecVector()
    {
        var expectedFingerprint = "CPGW-O6WE-FDKX-WXFU-GSVC-JBWJ-6MHP-4GFQ";
        var actualFingerprint = IdentityManager.DeriveFingerprint(TestPublicKey);
        
        Assert.Equal(expectedFingerprint, actualFingerprint);
    }
    
    [Fact]
    public void Test_EnsureIdentityInitialized_CreatesValidExtensions()
    {
        var manager = new IdentityManager();
        manager.EnsureIdentityInitialized();
        
        var cert = manager.GetTlsCertificate();
        Assert.NotNull(cert);
        
        var edKey = manager.GetEd25519PublicKey();
        Assert.NotNull(edKey);
        
        // Parse with BouncyCastle to avoid Windows Crypt32 throws on unknown extensions
        var bcParser = new Org.BouncyCastle.X509.X509CertificateParser();
        var bcCert = bcParser.ReadCertificate(cert.RawData);
        var extValue = bcCert.GetExtensionValue(new Org.BouncyCastle.Asn1.DerObjectIdentifier("2.25.293029629918709742181702189012786017422"));
        
        Assert.NotNull(extValue);
        
        // The persisted parser accepts both the direct OCTET STRING form
        // (`04 20 <32 bytes>`) and the double-wrapped form
        // (`04 22 04 20 <32 bytes>`), so the test should mirror that.
        var rawData = extValue.GetOctets();
        byte[] embeddedKeyBytes;
        if (rawData.Length == 36)
        {
            Assert.Equal(0x04, rawData[0]);
            Assert.Equal(0x22, rawData[1]);
            Assert.Equal(0x04, rawData[2]);
            Assert.Equal(0x20, rawData[3]);
            embeddedKeyBytes = rawData.AsSpan(4).ToArray();
        }
        else
        {
            Assert.Equal(34, rawData.Length);
            Assert.Equal(0x04, rawData[0]);
            Assert.Equal(0x20, rawData[1]);
            embeddedKeyBytes = rawData.AsSpan(2).ToArray();
        }

        Assert.True(edKey.SequenceEqual(embeddedKeyBytes));
    }

    [Fact]
    public void Test_SignEd25519_RoundTrip_SignatureVerifies()
    {
        var manager = new IdentityManager();
        var dataToSign = System.Text.Encoding.UTF8.GetBytes("Rift protocol test payload");

        var signature = manager.SignEd25519(dataToSign);
        var pubKeyBytes = manager.GetEd25519PublicKey();

        // Verify with BouncyCastle
        var pubKeyParams = new Org.BouncyCastle.Crypto.Parameters.Ed25519PublicKeyParameters(pubKeyBytes, 0);
        var verifier = Org.BouncyCastle.Security.SignerUtilities.GetSigner("Ed25519");
        verifier.Init(false, pubKeyParams);
        verifier.BlockUpdate(dataToSign, 0, dataToSign.Length);
        
        var isValid = verifier.VerifySignature(signature);
        Assert.True(isValid);
    }

    [Theory]
    [InlineData(true, false, X509KeyStorageFlags.Exportable)]
    [InlineData(false, true, X509KeyStorageFlags.Exportable)]
    [InlineData(false, false, X509KeyStorageFlags.Exportable | X509KeyStorageFlags.EphemeralKeySet)]
    public void GetPkcs12LoadFlags_UsesPlatformCompatibleStorageFlags(bool isWindows, bool isMacOs, X509KeyStorageFlags expectedFlags)
    {
        var actualFlags = IdentityManager.GetPkcs12LoadFlags(isWindows, isMacOs);

        Assert.Equal(expectedFlags, actualFlags);
    }
}
