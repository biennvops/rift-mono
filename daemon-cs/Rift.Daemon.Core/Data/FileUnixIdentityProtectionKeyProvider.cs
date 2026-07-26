using System.Security.Cryptography;
using Rift.Daemon.Core.Interfaces;

namespace Rift.Daemon.Core.Data;

public sealed class FileUnixIdentityProtectionKeyProvider : IUnixIdentityProtectionKeyProvider
{
    private const int KeyLength = 32;

    public string BackendName => "file";

    public byte[] GetOrCreateKey(string keyFilePath, string? legacyKeyFilePath)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(keyFilePath)!);

        var existingKey = LoadExistingKey(keyFilePath);
        if (existingKey is not null)
        {
            return existingKey;
        }

        var key = RandomNumberGenerator.GetBytes(KeyLength);
        try
        {
            using (var stream = new FileStream(
                       keyFilePath,
                       FileMode.CreateNew,
                       FileAccess.Write,
                       FileShare.None))
            {
                stream.Write(key, 0, key.Length);
            }
            if (OperatingSystem.IsLinux() || OperatingSystem.IsMacOS())
            {
                File.SetUnixFileMode(
                    keyFilePath,
                    UnixFileMode.UserRead | UnixFileMode.UserWrite);
            }
        }
        catch (IOException)
        {
            existingKey = LoadExistingKey(keyFilePath);
            if (existingKey is not null)
            {
                return existingKey;
            }
            throw;
        }

        return key;
    }

    public byte[] GetOrCreateKey(string keyFilePath, byte[] key)
    {
        if (key.Length != KeyLength)
        {
            throw new InvalidOperationException("Unix identity protection key was malformed.");
        }

        Directory.CreateDirectory(Path.GetDirectoryName(keyFilePath)!);
        var existingKey = LoadExistingKey(keyFilePath);
        if (existingKey is not null)
        {
            return existingKey;
        }

        try
        {
            using var stream = new FileStream(
                keyFilePath,
                FileMode.CreateNew,
                FileAccess.Write,
                FileShare.None);
            stream.Write(key, 0, key.Length);
        }
        catch (IOException)
        {
            existingKey = LoadExistingKey(keyFilePath);
            if (existingKey is not null)
            {
                return existingKey;
            }
            throw;
        }

        if (OperatingSystem.IsLinux() || OperatingSystem.IsMacOS())
        {
            File.SetUnixFileMode(
                keyFilePath,
                UnixFileMode.UserRead | UnixFileMode.UserWrite);
        }
        return key;
    }

    public byte[]? GetExistingKey(string keyFilePath, string? legacyKeyFilePath) =>
        LoadExistingKey(keyFilePath) ??
        (legacyKeyFilePath is null ? null : LoadExistingKey(legacyKeyFilePath));

    public void OnKeyUseSucceeded(string keyFilePath, string? legacyKeyFilePath)
    {
    }

    private static byte[]? LoadExistingKey(string keyFilePath)
    {
        if (!File.Exists(keyFilePath))
        {
            return null;
        }

        var existingKey = File.ReadAllBytes(keyFilePath);
        if (existingKey.Length != KeyLength)
        {
            throw new InvalidOperationException("Unix identity protection key was malformed.");
        }

        return existingKey;
    }
}
