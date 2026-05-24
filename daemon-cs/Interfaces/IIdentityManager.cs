namespace Rift.Daemon.Windows.Interfaces;

public interface IIdentityManager
{
    ReadOnlySpan<byte> GetPublicKey();
    ReadOnlySpan<byte> GetCertificate();
    Task EnsureIdentityAsync();
}
