using System.Reflection;
using Microsoft.Data.Sqlite;
using Rift.Daemon.Core.Data;

namespace Rift.Daemon.Tests.Core;

public sealed class DatabaseContextTests : IDisposable
{
    private readonly string _databasePath;
    private readonly DatabaseContext _databaseContext;

    public DatabaseContextTests()
    {
        _databasePath = Path.Combine(Path.GetTempPath(), $"rift-dbctx-{Guid.NewGuid():N}.db");
        _databaseContext = new DatabaseContext(_databasePath);
    }

    [Fact]
    public void Initialize_CreatesSchemaWithSafeMigrationHelper()
    {
        _databaseContext.Initialize();

        using var connection = _databaseContext.CreateOpenConnection();
        using var command = connection.CreateCommand();
        command.CommandText = "PRAGMA table_info(LocalIdentity);";

        using var reader = command.ExecuteReader();
        var columnNames = new List<string>();
        while (reader.Read())
        {
            columnNames.Add((string)reader["name"]);
        }

        Assert.Contains("TlsCertificatePfx", columnNames);
    }

    [Fact]
    public void Initialize_AllowsLocalIdentitySecretsToBeNullable()
    {
        _databaseContext.Initialize();

        using var connection = _databaseContext.CreateOpenConnection();
        using var command = connection.CreateCommand();
        command.CommandText = "PRAGMA table_info(LocalIdentity);";

        using var reader = command.ExecuteReader();
        var notNullMap = new Dictionary<string, bool>(StringComparer.Ordinal);
        while (reader.Read())
        {
            notNullMap[(string)reader["name"]] = Convert.ToInt32(reader["notnull"]) != 0;
        }

        Assert.False(notNullMap["Ed25519PrivateKey"]);
        Assert.False(notNullMap["TlsCertificatePfx"]);
        Assert.True(notNullMap["Ed25519PublicKey"]);
    }

    [Fact]
    public void EnsureColumnExists_RejectsUnsafeSqlTokens()
    {
        _databaseContext.Initialize();

        using var connection = _databaseContext.CreateOpenConnection();
        var method = typeof(DatabaseContext).GetMethod("EnsureColumnExists", BindingFlags.NonPublic | BindingFlags.Static);
        Assert.NotNull(method);

        var ex = Assert.Throws<TargetInvocationException>(() =>
            method!.Invoke(null, [connection, "LocalIdentity; DROP TABLE Peers;--", "InjectedColumn", "TEXT NULL"]));

        Assert.IsType<ArgumentException>(ex.InnerException);
        Assert.Contains("Unsafe SQL identifier", ex.InnerException!.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void EnsureColumnExists_RejectsUnsafeColumnDefinition()
    {
        _databaseContext.Initialize();

        using var connection = _databaseContext.CreateOpenConnection();
        var method = typeof(DatabaseContext).GetMethod("EnsureColumnExists", BindingFlags.NonPublic | BindingFlags.Static);
        Assert.NotNull(method);

        var ex = Assert.Throws<TargetInvocationException>(() =>
            method!.Invoke(null, [connection, "LocalIdentity", "InjectedColumn", "TEXT NULL; DROP TABLE Peers;--"]));

        Assert.IsType<ArgumentException>(ex.InnerException);
        Assert.Contains("Unsafe SQL column definition", ex.InnerException!.Message, StringComparison.Ordinal);
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
