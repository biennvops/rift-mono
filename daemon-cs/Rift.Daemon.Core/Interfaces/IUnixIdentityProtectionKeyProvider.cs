namespace Rift.Daemon.Core.Interfaces;

public interface IUnixIdentityProtectionKeyProvider
{
    string BackendName { get; }

    byte[] GetOrCreateKey(string keyFilePath, string? legacyKeyFilePath);

    byte[]? GetExistingKey(string keyFilePath, string? legacyKeyFilePath);

    void OnKeyUseSucceeded(string keyFilePath, string? legacyKeyFilePath);
}
