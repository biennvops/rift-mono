using System.Security.Cryptography.X509Certificates;

namespace Rift.Daemon.Core.Interfaces;

public interface IIdentityManager
{
    void EnsureIdentityInitialized();

    string GetDeviceId();

    byte[] GetEd25519PublicKey();

    X509Certificate2 GetTlsCertificate();

    byte[] SignEd25519(byte[] data);

    string GetFingerprint();
}
