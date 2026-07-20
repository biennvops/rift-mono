using System.Security.Cryptography;
using System.Runtime.Versioning;
using Microsoft.Extensions.Logging.Abstractions;
using Rift.Daemon.Core.Cryptography;
using Rift.Daemon.Core.Data;
using Rift.Daemon.Linux;

namespace Rift.Daemon.Tests.Core;

[SupportedOSPlatform("linux")]
public sealed class LinuxSecretServiceIdentityProtectionTests : IDisposable
{
    private readonly string _tempDirectory = Directory.CreateTempSubdirectory("rift-secret-service").FullName;

    [Fact]
    public void NewKey_IsStoredInSecretService()
    {
        var secrets = new FakeSecretStore();
        var provider = CreateProvider(secrets);
        var keyPath = Path.Combine(_tempDirectory, "identity.key");

        var key = provider.GetOrCreateKey(keyPath, null);

        Assert.Equal(32, key.Length);
        Assert.Equal("secret-service", provider.BackendName);
        Assert.Equal(key, secrets.StoredKey);
        Assert.False(File.Exists(keyPath));
    }

    [Fact]
    public void UnavailableSecretService_UsesMode0600FileFallback()
    {
        var secrets = new FakeSecretStore { Status = SecretLookupStatus.Unavailable };
        var provider = CreateProvider(secrets);
        var keyPath = Path.Combine(_tempDirectory, "fallback.key");

        var key = provider.GetOrCreateKey(keyPath, null);

        Assert.Equal("file", provider.BackendName);
        Assert.Equal(key, File.ReadAllBytes(keyPath));
        Assert.Equal(
            UnixFileMode.UserRead | UnixFileMode.UserWrite,
            File.GetUnixFileMode(keyPath));
    }

    [Fact]
    public void ExistingFileKey_IsRemovedOnlyAfterSuccessfulUse()
    {
        var secrets = new FakeSecretStore();
        var provider = CreateProvider(secrets);
        var keyPath = Path.Combine(_tempDirectory, "legacy.key");
        var key = Enumerable.Range(0, 32).Select(value => (byte)value).ToArray();
        File.WriteAllBytes(keyPath, key);

        Assert.Equal(key, provider.GetExistingKey(keyPath, null));
        Assert.True(File.Exists(keyPath));

        provider.OnKeyUseSucceeded(keyPath, null);

        Assert.False(File.Exists(keyPath));
        Assert.Equal(key, secrets.StoredKey);
        Assert.Equal("secret-service", provider.BackendName);
    }

    [Fact]
    public void MalformedSecretServiceKey_IsRejected()
    {
        var secrets = new FakeSecretStore
        {
            Status = SecretLookupStatus.Found,
            StoredKey = [1, 2, 3]
        };
        var provider = CreateProvider(secrets);

        var exception = Assert.Throws<InvalidOperationException>(() =>
            provider.GetExistingKey(Path.Combine(_tempDirectory, "identity.key"), null));

        Assert.Contains("malformed", exception.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void CorruptIdentity_DoesNotRemoveFallbackKeyDuringMigration()
    {
        var databasePath = Path.Combine(_tempDirectory, "corrupt.sqlite3");
        var database = new DatabaseContext(databasePath);
        database.Initialize();
        var originalManager = new IdentityManager(new SqliteLocalIdentityStore(database));
        _ = originalManager.GetDeviceId();
        var keyPath = Path.Combine(_tempDirectory, "corrupt.sqlite3.rift-secrets.key");

        using (var connection = database.CreateOpenConnection())
        using (var select = connection.CreateCommand())
        {
            select.CommandText = "SELECT Ed25519PrivateKey FROM LocalIdentity WHERE Id = 1;";
            var protectedKey = (byte[])select.ExecuteScalar()!;
            protectedKey[^1] ^= 0xff;
            using var update = connection.CreateCommand();
            update.CommandText = "UPDATE LocalIdentity SET Ed25519PrivateKey = $privateKey WHERE Id = 1;";
            update.Parameters.AddWithValue("$privateKey", protectedKey);
            update.ExecuteNonQuery();
        }

        var secrets = new FakeSecretStore();
        var migratingManager = new IdentityManager(
            new SqliteLocalIdentityStore(database, CreateProvider(secrets)));

        Assert.Throws<AuthenticationTagMismatchException>(() => migratingManager.GetDeviceId());
        Assert.True(File.Exists(keyPath));
        Assert.NotNull(secrets.StoredKey);
    }

    [Fact]
    public void SqliteIdentityMigration_PreservesDeviceIdentityAcrossRestart()
    {
        var databasePath = Path.Combine(_tempDirectory, "riftd.sqlite3");
        var database = new DatabaseContext(databasePath);
        database.Initialize();
        var originalManager = new IdentityManager(new SqliteLocalIdentityStore(database));
        var originalDeviceId = originalManager.GetDeviceId();
        var keyPath = Path.Combine(_tempDirectory, "riftd.sqlite3.rift-secrets.key");
        Assert.True(File.Exists(keyPath));

        var secrets = new FakeSecretStore();
        var migratingManager = new IdentityManager(
            new SqliteLocalIdentityStore(database, CreateProvider(secrets)));

        Assert.Equal(originalDeviceId, migratingManager.GetDeviceId());
        Assert.False(File.Exists(keyPath));

        secrets.Status = SecretLookupStatus.Found;
        var restartedManager = new IdentityManager(
            new SqliteLocalIdentityStore(database, CreateProvider(secrets)));
        Assert.Equal(originalDeviceId, restartedManager.GetDeviceId());
    }

    public void Dispose()
    {
        Directory.Delete(_tempDirectory, recursive: true);
    }

    private static LinuxSecretServiceIdentityProtectionKeyProvider CreateProvider(
        ILinuxSecretStore secretStore) => new(
            secretStore,
            NullLogger<LinuxSecretServiceIdentityProtectionKeyProvider>.Instance);

    private sealed class FakeSecretStore : ILinuxSecretStore
    {
        public SecretLookupStatus Status { get; set; } = SecretLookupStatus.Missing;
        public byte[]? StoredKey { get; set; }

        public SecretLookupResult Get(string scope) => new(Status, StoredKey);

        public bool Store(string scope, byte[] key)
        {
            StoredKey = key.ToArray();
            Status = SecretLookupStatus.Found;
            return true;
        }
    }
}
