using System.Security.Cryptography.X509Certificates;

namespace Rift.Daemon.Core.Interfaces;

public interface IIdentityManager
{
    /// <summary>
    /// Ensures that the dual-keypair identity (Ed25519 + ECDSA P-256 TLS cert) is initialized.
    /// Creates them and persists to the secure store if they do not exist.
    /// </summary>
    void EnsureIdentityInitialized();

    /// <summary>
    /// Gets the Device ID derived from the Ed25519 public key hash.
    /// </summary>
    string GetDeviceId();

    /// <summary>
    /// Gets the Ed25519 public key byte array.
    /// </summary>
    byte[] GetEd25519PublicKey();

    /// <summary>
    /// Gets the ECDSA P-256 TLS certificate which embeds the Ed25519 public key in a custom extension.
    /// </summary>
    X509Certificate2 GetTlsCertificate();

    /// <summary>
    /// Signs the given data using the Ed25519 private key for Proof of Possession.
    /// </summary>
    byte[] SignEd25519(byte[] data);

    /// <summary>
    /// Gets the pairing fingerprint (e.g. ABCD-EFGH-...).
    /// </summary>
    string GetFingerprint();
}
