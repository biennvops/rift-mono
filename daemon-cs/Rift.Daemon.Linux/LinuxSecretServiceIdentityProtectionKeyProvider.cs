using System.Security.Cryptography;
using System.Text;
using DBus.Services.Secrets;
using Rift.Daemon.Core.Data;
using Rift.Daemon.Core.Interfaces;

namespace Rift.Daemon.Linux;

internal enum SecretLookupStatus
{
    Unavailable,
    Missing,
    Found
}

internal sealed record SecretLookupResult(SecretLookupStatus Status, byte[]? Key = null);

internal interface ILinuxSecretStore
{
    SecretLookupResult Get(string scope);

    bool Store(string scope, byte[] key);
}

internal sealed class LinuxSecretStore(ILogger<LinuxSecretStore> logger) : ILinuxSecretStore
{
    private const string Label = "Rift device identity protection key";
    private const string ContentType = "application/octet-stream";

    public SecretLookupResult Get(string scope)
    {
        try
        {
            var collection = GetDefaultCollection();
            if (collection is null)
            {
                return new SecretLookupResult(SecretLookupStatus.Unavailable);
            }

            var items = collection.SearchItemsAsync(CreateAttributes(scope)).GetAwaiter().GetResult();
            if (items.Length == 0)
            {
                return new SecretLookupResult(SecretLookupStatus.Missing);
            }

            var item = items[0];
            if (item.IsLockedAsync().GetAwaiter().GetResult())
            {
                item.UnlockAsync().GetAwaiter().GetResult();
            }
            return new SecretLookupResult(
                SecretLookupStatus.Found,
                item.GetSecretAsync().GetAwaiter().GetResult());
        }
        catch (Exception ex)
        {
            logger.LogWarning(ex, "Linux Secret Service is unavailable for Rift identity protection.");
            return new SecretLookupResult(SecretLookupStatus.Unavailable);
        }
    }

    public bool Store(string scope, byte[] key)
    {
        try
        {
            var collection = GetDefaultCollection();
            if (collection is null)
            {
                return false;
            }

            var item = collection.CreateItemAsync(
                Label,
                CreateAttributes(scope),
                key,
                ContentType,
                replace: true).GetAwaiter().GetResult();
            return item is not null;
        }
        catch (Exception ex)
        {
            logger.LogWarning(ex, "Failed to store the Rift identity key in Linux Secret Service.");
            return false;
        }
    }

    private static Collection? GetDefaultCollection()
    {
        var service = SecretService.ConnectAsync(EncryptionType.Dh).GetAwaiter().GetResult();
        return service.GetDefaultCollectionAsync().GetAwaiter().GetResult();
    }

    private static Dictionary<string, string> CreateAttributes(string scope) => new(StringComparer.Ordinal)
    {
        ["application"] = "dev.rift.Rift",
        ["purpose"] = "identity-protection",
        ["scope"] = scope
    };
}

internal sealed class LinuxSecretServiceIdentityProtectionKeyProvider(
    ILinuxSecretStore secretStore,
    ILogger<LinuxSecretServiceIdentityProtectionKeyProvider> logger) : IUnixIdentityProtectionKeyProvider
{
    private const int KeyLength = 32;

    private readonly Lock _gate = new();
    private readonly FileUnixIdentityProtectionKeyProvider _fileProvider = new();
    private readonly Dictionary<string, byte[]> _cachedKeys = new(StringComparer.Ordinal);
    private readonly HashSet<string> _pendingFileMigrations = new(StringComparer.Ordinal);
    private string _backendName = "uninitialized";

    public string BackendName
    {
        get
        {
            lock (_gate)
            {
                return _backendName;
            }
        }
    }

    public byte[] GetOrCreateKey(string keyFilePath, string? legacyKeyFilePath)
    {
        lock (_gate)
        {
            var scope = CreateScope(keyFilePath);
            if (_cachedKeys.TryGetValue(scope, out var cached))
            {
                return cached;
            }

            var lookup = secretStore.Get(scope);
            if (lookup.Status == SecretLookupStatus.Found)
            {
                return CacheSecretKey(scope, lookup.Key);
            }

            var fileKey = _fileProvider.GetExistingKey(keyFilePath, legacyKeyFilePath);
            if (fileKey is not null)
            {
                if (lookup.Status == SecretLookupStatus.Missing && secretStore.Store(scope, fileKey))
                {
                    _pendingFileMigrations.Add(scope);
                    _backendName = "secret-service";
                }
                else
                {
                    _backendName = "file";
                }
                return Cache(scope, fileKey);
            }

            if (lookup.Status == SecretLookupStatus.Missing)
            {
                var key = RandomNumberGenerator.GetBytes(KeyLength);
                if (secretStore.Store(scope, key))
                {
                    _backendName = "secret-service";
                    return Cache(scope, key);
                }
            }

            _backendName = "file";
            logger.LogWarning(
                "Rift is using the filesystem fallback for Linux identity protection because Secret Service is unavailable.");
            return Cache(scope, _fileProvider.GetOrCreateKey(keyFilePath, legacyKeyFilePath));
        }
    }

    public byte[]? GetExistingKey(string keyFilePath, string? legacyKeyFilePath)
    {
        lock (_gate)
        {
            var scope = CreateScope(keyFilePath);
            if (_cachedKeys.TryGetValue(scope, out var cached))
            {
                return cached;
            }

            var lookup = secretStore.Get(scope);
            if (lookup.Status == SecretLookupStatus.Found)
            {
                return CacheSecretKey(scope, lookup.Key);
            }

            var fileKey = _fileProvider.GetExistingKey(keyFilePath, legacyKeyFilePath);
            if (fileKey is null)
            {
                _backendName = lookup.Status == SecretLookupStatus.Missing
                    ? "secret-service"
                    : "unavailable";
                return null;
            }

            if (lookup.Status == SecretLookupStatus.Missing && secretStore.Store(scope, fileKey))
            {
                _pendingFileMigrations.Add(scope);
                _backendName = "secret-service";
            }
            else
            {
                _backendName = "file";
            }
            return Cache(scope, fileKey);
        }
    }

    public void OnKeyUseSucceeded(string keyFilePath, string? legacyKeyFilePath)
    {
        lock (_gate)
        {
            var scope = CreateScope(keyFilePath);
            if (!_pendingFileMigrations.Remove(scope))
            {
                return;
            }

            DeleteMigratedFile(keyFilePath);
            if (legacyKeyFilePath is not null)
            {
                DeleteMigratedFile(legacyKeyFilePath);
            }
            logger.LogInformation("Migrated the Rift Linux identity protection key to Secret Service.");
        }
    }

    internal static string CreateScope(string keyFilePath)
    {
        var normalizedPath = Path.GetFullPath(keyFilePath);
        var digest = SHA256.HashData(Encoding.UTF8.GetBytes(normalizedPath));
        return Convert.ToHexStringLower(digest);
    }

    private byte[] CacheSecretKey(string scope, byte[]? key)
    {
        if (key is null || key.Length != KeyLength)
        {
            throw new InvalidOperationException("Linux Secret Service returned a malformed Rift identity key.");
        }
        _backendName = "secret-service";
        return Cache(scope, key);
    }

    private byte[] Cache(string scope, byte[] key)
    {
        if (key.Length != KeyLength)
        {
            throw new InvalidOperationException("Unix identity protection key was malformed.");
        }
        _cachedKeys[scope] = key;
        return key;
    }

    private void DeleteMigratedFile(string path)
    {
        try
        {
            if (File.Exists(path))
            {
                File.Delete(path);
            }
        }
        catch (Exception ex)
        {
            logger.LogWarning(ex, "Failed to remove migrated identity key file {Path}.", path);
        }
    }
}
