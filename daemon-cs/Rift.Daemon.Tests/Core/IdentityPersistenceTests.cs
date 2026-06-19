using Microsoft.Data.Sqlite;
using Rift.Daemon.Core.Cryptography;
using Rift.Daemon.Core.Data;
using Rift.Daemon.Core.Interfaces;

namespace Rift.Daemon.Tests.Core;

public sealed class IdentityPersistenceTests : IDisposable
{
    private readonly string _databasePath;
    private readonly DatabaseContext _databaseContext;

    public IdentityPersistenceTests()
    {
        _databasePath = Path.Combine(Path.GetTempPath(), $"rift-identity-{Guid.NewGuid():N}.db");
        _databaseContext = new DatabaseContext(_databasePath);
        _databaseContext.Initialize();
    }

    [Fact]
    public void IdentityManager_RestoresSameDeviceIdAcrossRestart()
    {
        var firstManager = new IdentityManager(new SqliteLocalIdentityStore(_databaseContext));
        var firstDeviceId = firstManager.GetDeviceId();
        var firstPublicKey = firstManager.GetEd25519PublicKey();

        var secondManager = new IdentityManager(new SqliteLocalIdentityStore(_databaseContext));
        var secondDeviceId = secondManager.GetDeviceId();
        var secondPublicKey = secondManager.GetEd25519PublicKey();

        Assert.Equal(firstDeviceId, secondDeviceId);
        Assert.Equal(firstPublicKey, secondPublicKey);
    }

    [Fact]
    public void IdentityManager_RestoresSameTlsCertificateAcrossRestart()
    {
        var firstManager = new IdentityManager(new SqliteLocalIdentityStore(_databaseContext));
        var firstCertificate = firstManager.GetTlsCertificate();
        var firstFingerprint = firstCertificate.GetCertHashString(System.Security.Cryptography.HashAlgorithmName.SHA256);

        var secondManager = new IdentityManager(new SqliteLocalIdentityStore(_databaseContext));
        var secondCertificate = secondManager.GetTlsCertificate();
        var secondFingerprint = secondCertificate.GetCertHashString(System.Security.Cryptography.HashAlgorithmName.SHA256);

        Assert.Equal(firstFingerprint, secondFingerprint);
        Assert.Equal(firstCertificate.RawData, secondCertificate.RawData);
    }

    [Fact]
    public void IdentityManager_PersistsPrivateKeyProtectedAtRestOnWindows()
    {
        var manager = new IdentityManager(new SqliteLocalIdentityStore(_databaseContext));
        manager.EnsureIdentityInitialized();

        using var connection = _databaseContext.CreateOpenConnection();
        using var command = connection.CreateCommand();
        command.CommandText = "SELECT Ed25519PrivateKey FROM LocalIdentity WHERE Id = 1;";
        var storedPrivateKey = (byte[])command.ExecuteScalar()!;
        var restoredPrivateKey = new SqliteLocalIdentityStore(_databaseContext).GetIdentity()!.Ed25519PrivateKey;

        Assert.NotEqual(manager.GetEd25519PublicKey(), storedPrivateKey);

        if (OperatingSystem.IsWindows())
        {
            Assert.False(storedPrivateKey.AsSpan().SequenceEqual(restoredPrivateKey));
        }
    }

    [Fact]
    public void IdentityManager_LegacyPersistedIdentityWithoutTlsCertificate_GeneratesAndPersistsTlsCertificate()
    {
        var seedDatabasePath = Path.Combine(Path.GetTempPath(), $"rift-identity-seed-{Guid.NewGuid():N}.db");
        try
        {
            var seedDatabaseContext = new DatabaseContext(seedDatabasePath);
            seedDatabaseContext.Initialize();
            var seedStore = new SqliteLocalIdentityStore(seedDatabaseContext);
            var seedManager = new IdentityManager(seedStore);
            seedManager.EnsureIdentityInitialized();
            var seededIdentity = seedStore.GetIdentity()!;

            using (var connection = _databaseContext.CreateOpenConnection())
            using (var command = connection.CreateCommand())
            {
                command.CommandText =
                    """
                    INSERT INTO LocalIdentity (Id, Ed25519PrivateKey, Ed25519PublicKey, TlsCertificatePfx, CreatedAt)
                    VALUES (1, $privateKey, $publicKey, NULL, $createdAt);
                    """;
                command.Parameters.AddWithValue("$privateKey", seededIdentity.Ed25519PrivateKey);
                command.Parameters.AddWithValue("$publicKey", seededIdentity.Ed25519PublicKey);
                command.Parameters.AddWithValue("$createdAt", seededIdentity.CreatedAt.ToString("O"));
                command.ExecuteNonQuery();
            }

            var manager = new IdentityManager(new SqliteLocalIdentityStore(_databaseContext));
            var certificate = manager.GetTlsCertificate();

            using var verifyConnection = _databaseContext.CreateOpenConnection();
            using var verifyCommand = verifyConnection.CreateCommand();
            verifyCommand.CommandText = "SELECT TlsCertificatePfx FROM LocalIdentity WHERE Id = 1;";
            var storedCertificate = verifyCommand.ExecuteScalar();

            Assert.NotNull(certificate);
            Assert.NotNull(storedCertificate);
        }
        finally
        {
            SqliteConnection.ClearAllPools();
            if (File.Exists(seedDatabasePath))
            {
                File.Delete(seedDatabasePath);
            }
        }
    }

    [Fact]
    public void IdentityManager_CorruptedPersistedIdentity_FailsClosed()
    {
        using var connection = _databaseContext.CreateOpenConnection();
        using var command = connection.CreateCommand();
        command.CommandText =
            """
            INSERT INTO LocalIdentity (Id, Ed25519PrivateKey, Ed25519PublicKey, CreatedAt)
            VALUES (1, $privateKey, $publicKey, $createdAt);
            """;
        command.Parameters.AddWithValue("$privateKey", new byte[] { 0x01, 0x02 });
        command.Parameters.AddWithValue("$publicKey", new byte[] { 0x03, 0x04 });
        command.Parameters.AddWithValue("$createdAt", DateTimeOffset.UtcNow.ToString("O"));
        command.ExecuteNonQuery();

        var manager = new IdentityManager(new SqliteLocalIdentityStore(_databaseContext));

        Assert.Throws<InvalidOperationException>(() => manager.EnsureIdentityInitialized());
    }

    public void Dispose()
    {
        SqliteConnection.ClearAllPools();
        if (File.Exists(_databasePath))
        {
            File.Delete(_databasePath);
        }
    }
}
