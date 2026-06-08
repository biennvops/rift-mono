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
        
        // extValue is an Asn1OctetString which contains the outer bytes
        var rawData = extValue.GetOctets();
        Assert.Equal(36, rawData.Length);
        
        // Ensure structure is: 04 22 04 20 <32 bytes>
        Assert.Equal(0x04, rawData[0]);
        Assert.Equal(0x22, rawData[1]);
        Assert.Equal(0x04, rawData[2]);
        Assert.Equal(0x20, rawData[3]);
        
        var embeddedKeyBytes = rawData.AsSpan(4).ToArray();
        Assert.True(edKey.SequenceEqual(embeddedKeyBytes));
    }
}
