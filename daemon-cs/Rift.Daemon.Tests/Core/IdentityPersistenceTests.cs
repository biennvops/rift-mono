using Microsoft.Data.Sqlite;
using Rift.Daemon.Core.Cryptography;
using Rift.Daemon.Core.Data;

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
