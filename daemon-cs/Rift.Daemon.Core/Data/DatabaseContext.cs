using Microsoft.Data.Sqlite;

namespace Rift.Daemon.Core.Data;

public sealed class DatabaseContext
{
    private readonly string _connectionString;

    public DatabaseContext(string databasePath)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(databasePath);

        var fullPath = Path.GetFullPath(databasePath);
        var directory = Path.GetDirectoryName(fullPath);
        if (string.IsNullOrWhiteSpace(directory))
        {
            throw new InvalidOperationException($"Could not determine parent directory for database path '{databasePath}'.");
        }

        Directory.CreateDirectory(directory);
        DatabasePath = fullPath;
        _connectionString = new SqliteConnectionStringBuilder
        {
            DataSource = fullPath,
            Mode = SqliteOpenMode.ReadWriteCreate,
            Cache = SqliteCacheMode.Shared
        }.ToString();
    }

    public string DatabasePath { get; }

    public void Initialize()
    {
        using var connection = CreateOpenConnection();
        using var command = connection.CreateCommand();
        command.CommandText =
            """
            PRAGMA foreign_keys = ON;

            CREATE TABLE IF NOT EXISTS LocalIdentity (
                Id INTEGER NOT NULL PRIMARY KEY CHECK (Id = 1),
                Ed25519PrivateKey BLOB NOT NULL,
                Ed25519PublicKey BLOB NOT NULL,
                CreatedAt TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS Peers (
                DeviceId TEXT NOT NULL PRIMARY KEY,
                Ed25519PublicKey BLOB NULL,
                State TEXT NOT NULL,
                CertificateFingerprint TEXT NULL,
                LastTransition TEXT NOT NULL,
                RevocationEvidence TEXT NULL
            );

            CREATE TABLE IF NOT EXISTS SecurityEvents (
                EventId TEXT NOT NULL PRIMARY KEY,
                EventType TEXT NOT NULL,
                Severity TEXT NOT NULL,
                LocalDeviceId TEXT NOT NULL,
                PeerDeviceId TEXT NULL,
                OperationId TEXT NULL,
                Timestamp TEXT NOT NULL,
                Outcome TEXT NOT NULL,
                FailureReason TEXT NULL,
                DetailsJson TEXT NULL
            );
            """;
        command.ExecuteNonQuery();
    }

    public SqliteConnection CreateOpenConnection()
    {
        var connection = new SqliteConnection(_connectionString);
        connection.Open();

        using var pragma = connection.CreateCommand();
        pragma.CommandText = "PRAGMA foreign_keys = ON;";
        pragma.ExecuteNonQuery();

        return connection;
    }
}
