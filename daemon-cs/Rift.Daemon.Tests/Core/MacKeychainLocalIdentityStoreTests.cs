using Microsoft.Data.Sqlite;
using Rift.Daemon.Core.Cryptography;
using Rift.Daemon.Core.Data;
using Rift.Daemon.Core.Interfaces;

namespace Rift.Daemon.Tests.Core;

public sealed class MacKeychainLocalIdentityStoreTests : IDisposable
{
    private readonly string _databasePath;
    private readonly DatabaseContext _databaseContext;

    public MacKeychainLocalIdentityStoreTests()
    {
        _databasePath = Path.Combine(Path.GetTempPath(), $"rift-mac-keychain-{Guid.NewGuid():N}.db");
        _databaseContext = new DatabaseContext(_databasePath);
        _databaseContext.Initialize();
    }

    [Fact]
    public void SaveIdentity_PersistsSecretsToKeychainAndOnlyMetadataToSqlite()
    {
        var keychain = new FakeMacKeychain();
        var store = new MacKeychainLocalIdentityStore(_databaseContext, keychain);
        var identity = CreateIdentityRecord();

        store.SaveIdentity(identity);
        var restored = store.GetIdentity();

        Assert.NotNull(restored);
        Assert.Equal(identity.Ed25519PrivateKey, restored!.Ed25519PrivateKey);
        Assert.Equal(identity.Ed25519PublicKey, restored.Ed25519PublicKey);
        Assert.Equal(identity.TlsCertificatePfx, restored.TlsCertificatePfx);
        Assert.Equal(identity.CreatedAt, restored.CreatedAt);

        var row = ReadLocalIdentityRow();
        Assert.Null(row.Ed25519PrivateKey);
        Assert.Equal(identity.Ed25519PublicKey, row.Ed25519PublicKey);
        Assert.Null(row.TlsCertificatePfx);
        Assert.Equal(identity.CreatedAt, row.CreatedAt);

        Assert.Equal(identity.Ed25519PrivateKey, keychain.GetSecret(MacKeychainLocalIdentityStore.ServiceName, MacKeychainLocalIdentityStore.PrivateKeyAccount));
        Assert.Equal(identity.TlsCertificatePfx, keychain.GetSecret(MacKeychainLocalIdentityStore.ServiceName, MacKeychainLocalIdentityStore.TlsCertificateAccount));
    }

    [Fact]
    public void GetIdentity_MigratesLegacySqliteSecretsIntoKeychain()
    {
        var legacyIdentity = CreateIdentityRecord();
        new SqliteLocalIdentityStore(_databaseContext).SaveIdentity(legacyIdentity);

        var keychain = new FakeMacKeychain();
        var store = new MacKeychainLocalIdentityStore(_databaseContext, keychain);

        var restored = store.GetIdentity();

        Assert.NotNull(restored);
        Assert.Equal(legacyIdentity.Ed25519PrivateKey, restored!.Ed25519PrivateKey);
        Assert.Equal(legacyIdentity.Ed25519PublicKey, restored.Ed25519PublicKey);
        Assert.Equal(legacyIdentity.TlsCertificatePfx, restored.TlsCertificatePfx);

        var row = ReadLocalIdentityRow();
        Assert.Null(row.Ed25519PrivateKey);
        Assert.Null(row.TlsCertificatePfx);
        Assert.Equal(legacyIdentity.Ed25519PublicKey, row.Ed25519PublicKey);

        Assert.Equal(legacyIdentity.Ed25519PrivateKey, keychain.GetSecret(MacKeychainLocalIdentityStore.ServiceName, MacKeychainLocalIdentityStore.PrivateKeyAccount));
        Assert.Equal(legacyIdentity.TlsCertificatePfx, keychain.GetSecret(MacKeychainLocalIdentityStore.ServiceName, MacKeychainLocalIdentityStore.TlsCertificateAccount));
    }

    [Fact]
    public void GetIdentity_WithKeychainSecretsAndMissingMetadata_RebuildsMetadataRow()
    {
        var identity = CreateIdentityRecord();
        var keychain = new FakeMacKeychain();
        keychain.SetSecret(MacKeychainLocalIdentityStore.ServiceName, MacKeychainLocalIdentityStore.PrivateKeyAccount, identity.Ed25519PrivateKey);
        keychain.SetSecret(MacKeychainLocalIdentityStore.ServiceName, MacKeychainLocalIdentityStore.TlsCertificateAccount, identity.TlsCertificatePfx!);

        var store = new MacKeychainLocalIdentityStore(_databaseContext, keychain);

        var restored = store.GetIdentity();

        Assert.NotNull(restored);
        Assert.Equal(identity.Ed25519PrivateKey, restored!.Ed25519PrivateKey);
        Assert.Equal(identity.Ed25519PublicKey, restored.Ed25519PublicKey);

        var row = ReadLocalIdentityRow();
        Assert.Equal(identity.Ed25519PublicKey, row.Ed25519PublicKey);
        Assert.NotEqual(default, row.CreatedAt);
        Assert.Null(row.Ed25519PrivateKey);
        Assert.Null(row.TlsCertificatePfx);
    }

    [Fact]
    public void GetIdentity_WhenMetadataPublicKeyDoesNotMatchKeychain_FailsClosed()
    {
        var firstIdentity = CreateIdentityRecord();
        var secondIdentity = CreateIdentityRecord();

        var keychain = new FakeMacKeychain();
        keychain.SetSecret(MacKeychainLocalIdentityStore.ServiceName, MacKeychainLocalIdentityStore.PrivateKeyAccount, firstIdentity.Ed25519PrivateKey);
        keychain.SetSecret(MacKeychainLocalIdentityStore.ServiceName, MacKeychainLocalIdentityStore.TlsCertificateAccount, firstIdentity.TlsCertificatePfx!);

        using var connection = _databaseContext.CreateOpenConnection();
        using var command = connection.CreateCommand();
        command.CommandText =
            """
            INSERT INTO LocalIdentity (Id, Ed25519PrivateKey, Ed25519PublicKey, TlsCertificatePfx, CreatedAt)
            VALUES (1, NULL, $publicKey, NULL, $createdAt);
            """;
        command.Parameters.AddWithValue("$publicKey", secondIdentity.Ed25519PublicKey);
        command.Parameters.AddWithValue("$createdAt", DateTimeOffset.UtcNow.ToString("O"));
        command.ExecuteNonQuery();

        var store = new MacKeychainLocalIdentityStore(_databaseContext, keychain);

        var ex = Assert.Throws<InvalidOperationException>(() => store.GetIdentity());
        Assert.Contains("did not match", ex.Message, StringComparison.Ordinal);
    }

    public void Dispose()
    {
        SqliteConnection.ClearAllPools();
        if (File.Exists(_databasePath))
        {
            File.Delete(_databasePath);
        }
    }

    private LocalIdentityRecord CreateIdentityRecord()
    {
        var seedPath = Path.Combine(Path.GetTempPath(), $"rift-mac-keychain-seed-{Guid.NewGuid():N}.db");
        try
        {
            var seedDatabase = new DatabaseContext(seedPath);
            seedDatabase.Initialize();
            var identityManager = new IdentityManager(new SqliteLocalIdentityStore(seedDatabase));
            identityManager.EnsureIdentityInitialized();

            return new LocalIdentityRecord
            {
                Ed25519PrivateKey = new SqliteLocalIdentityStore(seedDatabase).GetIdentity()!.Ed25519PrivateKey,
                Ed25519PublicKey = identityManager.GetEd25519PublicKey(),
                TlsCertificatePfx = IdentityManager.ExportPersistedTlsCertificate(identityManager.GetTlsCertificate()),
                CreatedAt = DateTimeOffset.UtcNow
            };
        }
        finally
        {
            SqliteConnection.ClearAllPools();
            if (File.Exists(seedPath))
            {
                File.Delete(seedPath);
            }
        }
    }

    private LocalIdentityRow ReadLocalIdentityRow()
    {
        using var connection = _databaseContext.CreateOpenConnection();
        using var command = connection.CreateCommand();
        command.CommandText =
            """
            SELECT Ed25519PrivateKey, Ed25519PublicKey, TlsCertificatePfx, CreatedAt
            FROM LocalIdentity
            WHERE Id = 1;
            """;

        using var reader = command.ExecuteReader();
        Assert.True(reader.Read());

        return new LocalIdentityRow(
            reader["Ed25519PrivateKey"] as byte[],
            (byte[])reader["Ed25519PublicKey"],
            reader["TlsCertificatePfx"] as byte[],
            DateTimeOffset.Parse((string)reader["CreatedAt"]));
    }

    private sealed record LocalIdentityRow(
        byte[]? Ed25519PrivateKey,
        byte[] Ed25519PublicKey,
        byte[]? TlsCertificatePfx,
        DateTimeOffset CreatedAt);

    private sealed class FakeMacKeychain : IMacKeychain
    {
        private readonly Dictionary<string, byte[]> _items = new(StringComparer.Ordinal);

        public byte[]? GetSecret(string service, string account)
        {
            return _items.TryGetValue($"{service}:{account}", out var value) ? value.ToArray() : null;
        }

        public void SetSecret(string service, string account, byte[] secret)
        {
            _items[$"{service}:{account}"] = secret.ToArray();
        }

        public void DeleteSecret(string service, string account)
        {
            _items.Remove($"{service}:{account}");
        }
    }
}
