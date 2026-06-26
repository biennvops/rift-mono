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
using System.Runtime.InteropServices;

namespace Rift.Daemon.Core.Cryptography;

public class IdentityManager : IIdentityManager
{
    private readonly ILocalIdentityStore? _localIdentityStore;
    private volatile Ed25519PublicKeyParameters _ed25519PublicKey = null!;
    private volatile Ed25519PrivateKeyParameters _ed25519PrivateKey = null!;
    private volatile X509Certificate2 _tlsCertificate = null!;
    private readonly object _syncRoot = new();

    public IdentityManager(ILocalIdentityStore? localIdentityStore = null)
    {
        _localIdentityStore = localIdentityStore;
    }

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

            var persistedIdentity = _localIdentityStore?.GetIdentity();
            if (persistedIdentity is not null)
            {
                if (persistedIdentity.Ed25519PrivateKey.Length != 32 || persistedIdentity.Ed25519PublicKey.Length != 32)
                {
                    throw new InvalidOperationException("Persisted Ed25519 identity material was malformed.");
                }

                _ed25519PrivateKey = new Ed25519PrivateKeyParameters(persistedIdentity.Ed25519PrivateKey, 0);
                _ed25519PublicKey = new Ed25519PublicKeyParameters(persistedIdentity.Ed25519PublicKey, 0);

                if (persistedIdentity.TlsCertificatePfx is not null)
                {
                    _tlsCertificate = LoadPersistedTlsCertificate(persistedIdentity.TlsCertificatePfx, _ed25519PublicKey);
                }
            }
            else
            {
                var random = new SecureRandom();
                var ed25519Gen = new Ed25519KeyPairGenerator();
                ed25519Gen.Init(new Ed25519KeyGenerationParameters(random));
                var ed25519Pair = ed25519Gen.GenerateKeyPair();

                _ed25519PublicKey = (Ed25519PublicKeyParameters)ed25519Pair.Public;
                _ed25519PrivateKey = (Ed25519PrivateKeyParameters)ed25519Pair.Private;

                var createdAt = DateTimeOffset.UtcNow;
                _tlsCertificate = GenerateTlsCertificate(_ed25519PublicKey);
                PersistIdentity(createdAt);
            }

            if (_tlsCertificate is null)
            {
                _tlsCertificate = GenerateTlsCertificate(_ed25519PublicKey);
                PersistIdentity(persistedIdentity?.CreatedAt ?? DateTimeOffset.UtcNow);
            }
        }
    }

    private void PersistIdentity(DateTimeOffset createdAt)
    {
        _localIdentityStore?.SaveIdentity(new LocalIdentityRecord
        {
            Ed25519PrivateKey = _ed25519PrivateKey.GetEncoded(),
            Ed25519PublicKey = _ed25519PublicKey.GetEncoded(),
            TlsCertificatePfx = ExportPersistedTlsCertificate(_tlsCertificate),
            CreatedAt = createdAt
        });
    }

    private static byte[] ExportPersistedTlsCertificate(X509Certificate2 certificate)
    {
        return certificate.Export(X509ContentType.Pkcs12, string.Empty);
    }

    private static X509Certificate2 LoadPersistedTlsCertificate(byte[] pkcs12Bytes, Ed25519PublicKeyParameters expectedEd25519PublicKey)
    {
        try
        {
            var certificate = X509CertificateLoader.LoadPkcs12(
                pkcs12Bytes,
                string.Empty,
                X509KeyStorageFlags.Exportable | X509KeyStorageFlags.EphemeralKeySet);
            var embeddedKey = ExtractEmbeddedEd25519PublicKey(certificate);
            if (!embeddedKey.SequenceEqual(expectedEd25519PublicKey.GetEncoded()))
            {
                throw new InvalidOperationException("Persisted TLS certificate did not match the persisted Ed25519 identity.");
            }

            return certificate;
        }
        catch (CryptographicException ex)
        {
            throw new InvalidOperationException("Persisted TLS certificate material was malformed.", ex);
        }
    }

    private static byte[] ExtractEmbeddedEd25519PublicKey(X509Certificate2 certificate)
    {
        var bcParser = new Org.BouncyCastle.X509.X509CertificateParser();
        var bcCert = bcParser.ReadCertificate(certificate.RawData);
        var extValue = bcCert.GetExtensionValue(new DerObjectIdentifier("2.25.293029629918709742181702189012786017422"));
        if (extValue is null)
        {
            throw new InvalidOperationException("Persisted TLS certificate did not contain the Rift Ed25519 identity extension.");
        }

        var rawData = extValue.GetOctets();
        if (rawData.Length == 36 && rawData[0] == 0x04 && rawData[1] == 0x22 && rawData[2] == 0x04 && rawData[3] == 0x20)
        {
            return rawData.AsSpan(4).ToArray(); // Legacy triple-wrapped
        }
        else if (rawData.Length == 34 && rawData[0] == 0x04 && rawData[1] == 0x20)
        {
            return rawData.AsSpan(2).ToArray(); // Correct double-wrapped
        }
        else
        {
            throw new InvalidOperationException("Persisted TLS certificate contained a malformed Rift Ed25519 identity extension.");
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

    private static X509Certificate2 GenerateTlsCertificate(Ed25519PublicKeyParameters ed25519PublicKey)
    {
        var random = new SecureRandom();

        var ecGen = new ECKeyPairGenerator("ECDSA");
        ecGen.Init(new KeyGenerationParameters(random, 256));
        var ecPair = ecGen.GenerateKeyPair();

        var certGen = new X509V3CertificateGenerator();
        var dnName = new X509Name("CN=RiftDevice");
        certGen.SetIssuerDN(dnName);
        certGen.SetSubjectDN(dnName);

        var serialNumber = BigInteger.ProbablePrime(120, random);
        certGen.SetSerialNumber(serialNumber);

        var notBefore = DateTime.UtcNow.AddDays(-1);
        var notAfter = notBefore.AddYears(1);
        certGen.SetNotBefore(notBefore);
        certGen.SetNotAfter(notAfter);
        certGen.SetPublicKey(ecPair.Public);

        var extOid = new DerObjectIdentifier("2.25.293029629918709742181702189012786017422");
        // AddExtension automatically wraps the byte array in a DerOctetString and encodes it, resulting in the standard X.509 double-wrapping.
        certGen.AddExtension(extOid, false, ed25519PublicKey.GetEncoded());

        var signatureFactory = new Asn1SignatureFactory("SHA256WITHECDSA", ecPair.Private, random);
        var bouncyCert = certGen.Generate(signatureFactory);

        var store = new Org.BouncyCastle.Pkcs.Pkcs12StoreBuilder().Build();
        store.SetKeyEntry("rift", new Org.BouncyCastle.Pkcs.AsymmetricKeyEntry(ecPair.Private), new[] { new Org.BouncyCastle.Pkcs.X509CertificateEntry(bouncyCert) });
        using var ms = new MemoryStream();
        store.Save(ms, Array.Empty<char>(), random);

        // TODO: implement ephemeral key writing to macOS Keychain.
        var flags = X509KeyStorageFlags.Exportable;
        if (!RuntimeInformation.IsOSPlatform(OSPlatform.OSX))
        {
            flags |= X509KeyStorageFlags.EphemeralKeySet;
        }

        return X509CertificateLoader.LoadPkcs12(ms.ToArray(), string.Empty, flags);
    }
}
