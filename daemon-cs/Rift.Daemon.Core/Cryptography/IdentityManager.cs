using System;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using Org.BouncyCastle.Asn1;
using Org.BouncyCastle.Asn1.X509;
using Org.BouncyCastle.Crypto;
using Org.BouncyCastle.Crypto.Generators;
using Org.BouncyCastle.Crypto.Operators;
using Org.BouncyCastle.Crypto.Parameters;
using Org.BouncyCastle.Math;
using Org.BouncyCastle.Security;
using Org.BouncyCastle.X509;
using Rift.Daemon.Core.Interfaces;
using X509Extension = Org.BouncyCastle.Asn1.X509.X509Extension;

namespace Rift.Daemon.Core.Cryptography;

public class IdentityManager : IIdentityManager
{
    private volatile Ed25519PublicKeyParameters _ed25519PublicKey = null!;
    private Ed25519PrivateKeyParameters _ed25519PrivateKey = null!;
    private volatile X509Certificate2 _tlsCertificate = null!;
    private readonly object _syncRoot = new();

    // Note: Identity persistence is currently deferred. For now, a new identity
    // is generated on every process restart. This will be updated to load/save
    // from a secure store in a future PR to maintain a stable device ID.

    public void EnsureIdentityInitialized()
    {
        if (_tlsCertificate != null && _ed25519PublicKey != null)
        {
            return;
        }
        
        lock (_syncRoot)
        {
            if (_tlsCertificate != null && _ed25519PublicKey != null)
            {
                return;
            }

            // Generate Ed25519 keys
            var random = new SecureRandom();
            var ed25519Gen = new Ed25519KeyPairGenerator();
            ed25519Gen.Init(new Ed25519KeyGenerationParameters(random));
            var ed25519Pair = ed25519Gen.GenerateKeyPair();
            
            _ed25519PublicKey = (Ed25519PublicKeyParameters)ed25519Pair.Public;
            _ed25519PrivateKey = (Ed25519PrivateKeyParameters)ed25519Pair.Private;

            // Generate ECDSA P-256 for TLS
            var ecGen = new ECKeyPairGenerator("ECDSA");
            ecGen.Init(new KeyGenerationParameters(random, 256));
            var ecPair = ecGen.GenerateKeyPair();

            var certGen = new X509V3CertificateGenerator();
            
            // Subject and Issuer (Self-signed)
            var dnName = new X509Name("CN=RiftDevice");
            certGen.SetIssuerDN(dnName);
            certGen.SetSubjectDN(dnName);
            
            // Serial number
            var serialNumber = BigInteger.ProbablePrime(120, random);
            certGen.SetSerialNumber(serialNumber);
            
            // Validity (1 year)
            var notBefore = DateTime.UtcNow.AddDays(-1);
            var notAfter = notBefore.AddYears(1);
            certGen.SetNotBefore(notBefore);
            certGen.SetNotAfter(notAfter);
            
            // TLS Public Key
            certGen.SetPublicKey(ecPair.Public);

            // Custom Extension for Ed25519 Public Key
            // OID: 2.25.293029629918709742181702189012786017422
            var extOid = new DerObjectIdentifier("2.25.293029629918709742181702189012786017422");
            var edKeyBytes = _ed25519PublicKey.GetEncoded();
            var innerOctetString = new DerOctetString(edKeyBytes);
            var innerBytes = innerOctetString.GetEncoded(); // 04 20 <32 bytes>
            
            // AddExtension implicitly wraps the inner bytes in an outer OCTET STRING,
            // resulting in the required `04 22 04 20 <32 bytes>` on the wire.
            certGen.AddExtension(extOid, false, innerBytes);

            // Sign certificate
            var signatureFactory = new Asn1SignatureFactory("SHA256WITHECDSA", ecPair.Private, random);
            var bouncyCert = certGen.Generate(signatureFactory);

            // Convert to .NET X509Certificate2 with private key using pkcs12 format
            var store = new Org.BouncyCastle.Pkcs.Pkcs12StoreBuilder().Build();
            store.SetKeyEntry("rift", new Org.BouncyCastle.Pkcs.AsymmetricKeyEntry(ecPair.Private), new[] { new Org.BouncyCastle.Pkcs.X509CertificateEntry(bouncyCert) });
            using var ms = new MemoryStream();
            store.Save(ms, "password".ToCharArray(), random);
            
            _tlsCertificate = X509CertificateLoader.LoadPkcs12(ms.ToArray(), "password", X509KeyStorageFlags.Exportable | X509KeyStorageFlags.EphemeralKeySet);
        }
    }

    public string GetDeviceId()
    {
        EnsureIdentityInitialized();
        var edKeyBytes = _ed25519PublicKey.GetEncoded();
        return DeriveDeviceId(edKeyBytes);
    }
    
    public static string DeriveDeviceId(byte[] edKeyBytes)
    {
         using var sha256 = SHA256.Create();
         var hash = sha256.ComputeHash(edKeyBytes);
         var base32 = Base32Encoding.Encode(hash).Substring(0, 32);
         return $"rift-{base32}";
    }

    public byte[] GetEd25519PublicKey()
    {
        EnsureIdentityInitialized();
        return _ed25519PublicKey.GetEncoded();
    }

    public X509Certificate2 GetTlsCertificate()
    {
        EnsureIdentityInitialized();
        return _tlsCertificate;
    }

    public byte[] SignEd25519(byte[] data)
    {
        EnsureIdentityInitialized();
        var signer = SignerUtilities.GetSigner("Ed25519");
        signer.Init(true, _ed25519PrivateKey);
        signer.BlockUpdate(data, 0, data.Length);
        return signer.GenerateSignature();
    }

    public string GetFingerprint()
    {
        EnsureIdentityInitialized();
        var edKeyBytes = _ed25519PublicKey.GetEncoded();
        return DeriveFingerprint(edKeyBytes);
    }
    
    public static string DeriveFingerprint(byte[] edKeyBytes)
    {
        using var sha256 = SHA256.Create();
        var hash = sha256.ComputeHash(edKeyBytes);
        var base32 = Base32Encoding.Encode(hash).ToUpper().Substring(0, 32);
        
        // Chunk into 8 groups of 4 characters
        var chunks = Enumerable.Range(0, 8).Select(i => base32.Substring(i * 4, 4));
        return string.Join("-", chunks);
    }

    public bool VerifyEd25519(byte[] publicKey, byte[] data, byte[] signature)
    {
        var verifier = SignerUtilities.GetSigner("Ed25519");
        var pubKeyParam = new Ed25519PublicKeyParameters(publicKey, 0);
        verifier.Init(false, pubKeyParam);
        verifier.BlockUpdate(data, 0, data.Length);
        return verifier.VerifySignature(signature);
    }
}
