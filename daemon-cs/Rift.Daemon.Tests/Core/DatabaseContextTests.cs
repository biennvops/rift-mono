using System.Reflection;
using System.Text.Json;
using Microsoft.Data.Sqlite;
using Rift.Daemon.Core.Data;
using Rift.Daemon.Core.Interfaces;

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

        using var queueCommand = connection.CreateCommand();
        queueCommand.CommandText = "PRAGMA table_info(SendQueueItems);";
        using var queueReader = queueCommand.ExecuteReader();
        var queueColumns = new List<string>();
        while (queueReader.Read())
        {
            queueColumns.Add((string)queueReader["name"]);
        }

        Assert.Contains("QueueItemId", queueColumns);
        Assert.Contains("Status", queueColumns);

        using var policyCommand = connection.CreateCommand();
        policyCommand.CommandText = "PRAGMA table_info(NotificationSyncPolicy);";
        using var policyReader = policyCommand.ExecuteReader();
        var policyColumns = new List<string>();
        while (policyReader.Read())
        {
            policyColumns.Add((string)policyReader["name"]);
        }

        Assert.Contains("Enabled", policyColumns);
        Assert.Contains("BlacklistedPackagesJson", policyColumns);
        Assert.Contains("PolicyJson", policyColumns);
    }

    [Fact]
    public void NotificationSyncPolicyStore_RoundTripsPolicy()
    {
        _databaseContext.Initialize();
        var store = new SqliteNotificationSyncPolicyStore(_databaseContext);

        store.Save(new NotificationSyncPolicy
        {
            Enabled = false,
            Mode = NotificationSyncPolicyModes.Exclude,
            PackageNames = ["org.example.Secret", "org.example.Secret", " org.example.Chat ", ""]
        });
        var restored = store.Load();

        Assert.False(restored.Enabled);
        Assert.Equal(NotificationSyncPolicyModes.Exclude, restored.Mode);
        Assert.Equal(["org.example.Chat", "org.example.Secret"], restored.PackageNames);
    }

    [Fact]
    public void NotificationSyncPolicyStore_ProjectsIncludeModeFailClosedForLegacyReaders()
    {
        _databaseContext.Initialize();
        var store = new SqliteNotificationSyncPolicyStore(_databaseContext);

        store.Save(new NotificationSyncPolicy
        {
            Enabled = true,
            Mode = NotificationSyncPolicyModes.Include,
            PackageNames = ["com.example.allowed"]
        });

        using var connection = _databaseContext.CreateOpenConnection();
        using var command = connection.CreateCommand();
        command.CommandText =
            "SELECT Enabled, BlacklistedPackagesJson, PolicyJson FROM NotificationSyncPolicy WHERE Id = 1;";
        using var reader = command.ExecuteReader();
        Assert.True(reader.Read());
        Assert.Equal(0, reader.GetInt64(0));
        Assert.Equal("[]", reader.GetString(1));

        using var policyDocument = JsonDocument.Parse(reader.GetString(2));
        Assert.Equal(2, policyDocument.RootElement.GetProperty("version").GetInt32());
        Assert.Equal("include", policyDocument.RootElement.GetProperty("mode").GetString());
        Assert.Equal(
            "com.example.allowed",
            policyDocument.RootElement.GetProperty("packageNames")[0].GetString());

        var restored = store.Load();
        Assert.True(restored.Enabled);
        Assert.Equal(NotificationSyncPolicyModes.Include, restored.Mode);
        Assert.Equal(["com.example.allowed"], restored.PackageNames);
    }

    [Fact]
    public void NotificationSyncPolicyStore_MigratesLegacyBlacklistToExclude()
    {
        _databaseContext.Initialize();
        using (var connection = _databaseContext.CreateOpenConnection())
        using (var command = connection.CreateCommand())
        {
            command.CommandText =
                "INSERT INTO NotificationSyncPolicy (Id, Enabled, BlacklistedPackagesJson, PolicyJson) VALUES (1, 1, '[\" com.foo \", \"com.foo\"]', NULL);";
            command.ExecuteNonQuery();
        }

        var restored = new SqliteNotificationSyncPolicyStore(_databaseContext).Load();

        Assert.True(restored.Enabled);
        Assert.Equal(NotificationSyncPolicyModes.Exclude, restored.Mode);
        Assert.Equal(["com.foo"], restored.PackageNames);
    }

    [Fact]
    public void NotificationSyncPolicyStore_MigratesEmptyLegacyBlacklistToAll()
    {
        _databaseContext.Initialize();
        using (var connection = _databaseContext.CreateOpenConnection())
        using (var command = connection.CreateCommand())
        {
            command.CommandText =
                "INSERT INTO NotificationSyncPolicy (Id, Enabled, BlacklistedPackagesJson, PolicyJson) VALUES (1, 1, '[]', NULL);";
            command.ExecuteNonQuery();
        }

        var restored = new SqliteNotificationSyncPolicyStore(_databaseContext).Load();

        Assert.True(restored.Enabled);
        Assert.Equal(NotificationSyncPolicyModes.All, restored.Mode);
        Assert.Empty(restored.PackageNames);
    }

    [Fact]
    public void NotificationSyncPolicyStore_FailsClosedForWhitespaceOnlyLegacyPackage()
    {
        _databaseContext.Initialize();
        using (var connection = _databaseContext.CreateOpenConnection())
        using (var command = connection.CreateCommand())
        {
            command.CommandText =
                "INSERT INTO NotificationSyncPolicy (Id, Enabled, BlacklistedPackagesJson, PolicyJson) VALUES (1, 1, '[\"   \"]', NULL);";
            command.ExecuteNonQuery();
        }

        var restored = new SqliteNotificationSyncPolicyStore(_databaseContext).Load();

        Assert.False(restored.Enabled);
        Assert.Equal(NotificationSyncPolicyModes.All, restored.Mode);
        Assert.Empty(restored.PackageNames);
    }

    [Fact]
    public void NotificationSyncPolicyStore_FailsClosedForMalformedCanonicalPolicy()
    {
        _databaseContext.Initialize();
        using (var connection = _databaseContext.CreateOpenConnection())
        using (var command = connection.CreateCommand())
        {
            command.CommandText =
                "INSERT INTO NotificationSyncPolicy (Id, Enabled, BlacklistedPackagesJson, PolicyJson) VALUES (1, 1, '[\"com.stale\"]', 'not-json');";
            command.ExecuteNonQuery();
        }

        var restored = new SqliteNotificationSyncPolicyStore(_databaseContext).Load();

        Assert.False(restored.Enabled);
        Assert.Equal(NotificationSyncPolicyModes.All, restored.Mode);
        Assert.Empty(restored.PackageNames);
    }

    [Fact]
    public void NotificationSyncPolicyStore_FailsClosedForMalformedPersistedBlacklist()
    {
        _databaseContext.Initialize();
        using (var connection = _databaseContext.CreateOpenConnection())
        using (var command = connection.CreateCommand())
        {
            command.CommandText =
                "INSERT INTO NotificationSyncPolicy (Id, Enabled, BlacklistedPackagesJson) VALUES (1, 0, 'not-json');";
            command.ExecuteNonQuery();
        }

        var restored = new SqliteNotificationSyncPolicyStore(_databaseContext).Load();

        Assert.False(restored.Enabled);
        Assert.Equal(NotificationSyncPolicyModes.All, restored.Mode);
        Assert.Empty(restored.PackageNames);
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
