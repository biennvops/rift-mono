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
    private static readonly TimeSpan OperationTimeout = TimeSpan.FromSeconds(5);

    public SecretLookupResult Get(string scope)
    {
        try
        {
            return WaitForOperation(GetAsync(scope), OperationTimeout);
        }
        catch (TimeoutException ex)
        {
            logger.LogWarning(ex, "Linux Secret Service timed out; Rift will use the filesystem identity-key fallback.");
            return new SecretLookupResult(SecretLookupStatus.Unavailable);
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
            return WaitForOperation(StoreAsync(scope, key), OperationTimeout);
        }
        catch (TimeoutException ex)
        {
            logger.LogWarning(ex, "Linux Secret Service timed out while storing the Rift identity key; Rift will use the filesystem fallback.");
            return false;
        }
        catch (Exception ex)
        {
            logger.LogWarning(ex, "Failed to store the Rift identity key in Linux Secret Service.");
            return false;
        }
    }

    internal static T WaitForOperation<T>(Task<T> operation, TimeSpan timeout) =>
        operation.WaitAsync(timeout).GetAwaiter().GetResult();

    private static async Task<SecretLookupResult> GetAsync(string scope)
    {
        var collection = await GetDefaultCollectionAsync().ConfigureAwait(false);
        if (collection is null)
        {
            return new SecretLookupResult(SecretLookupStatus.Unavailable);
        }

        var items = await collection.SearchItemsAsync(CreateAttributes(scope)).ConfigureAwait(false);
        if (items.Length == 0)
        {
            return new SecretLookupResult(SecretLookupStatus.Missing);
        }

        var item = items[0];
        if (await item.IsLockedAsync().ConfigureAwait(false))
        {
            await item.UnlockAsync().ConfigureAwait(false);
        }
        return new SecretLookupResult(
            SecretLookupStatus.Found,
            await item.GetSecretAsync().ConfigureAwait(false));
    }

    private static async Task<bool> StoreAsync(string scope, byte[] key)
    {
        var collection = await GetDefaultCollectionAsync().ConfigureAwait(false);
        if (collection is null)
        {
            return false;
        }

        var item = await collection.CreateItemAsync(
            Label,
            CreateAttributes(scope),
            key,
            ContentType,
            replace: true).ConfigureAwait(false);
        return item is not null;
    }

    private static async Task<Collection?> GetDefaultCollectionAsync()
    {
        var service = await SecretService.ConnectAsync(EncryptionType.Dh).ConfigureAwait(false);
        return await service.GetDefaultCollectionAsync().ConfigureAwait(false);
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

            byte[]? generatedKey = null;
            if (lookup.Status == SecretLookupStatus.Missing)
            {
                generatedKey = RandomNumberGenerator.GetBytes(KeyLength);
                if (secretStore.Store(scope, generatedKey))
                {
                    _backendName = "secret-service";
                    return Cache(scope, generatedKey);
                }
            }

            _backendName = "file";
            logger.LogWarning(
                "Rift is using the filesystem fallback for Linux identity protection because Secret Service is unavailable.");
            return Cache(
                scope,
                generatedKey is null
                    ? _fileProvider.GetOrCreateKey(keyFilePath, legacyKeyFilePath)
                    : _fileProvider.GetOrCreateKey(keyFilePath, generatedKey));
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
