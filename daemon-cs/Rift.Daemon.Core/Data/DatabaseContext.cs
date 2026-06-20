using Microsoft.Data.Sqlite;
using System.Text.RegularExpressions;

namespace Rift.Daemon.Core.Data;

public sealed class DatabaseContext
{
    private const int BusyTimeoutMs = 5000;
    private static readonly Regex SqlIdentifierPattern = new("^[A-Za-z_][A-Za-z0-9_]*$", RegexOptions.Compiled);
    private static readonly Regex ColumnDefinitionPattern = new("^[A-Za-z0-9_(), ]+$", RegexOptions.Compiled);
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
            PRAGMA journal_mode = WAL;
            PRAGMA busy_timeout = 5000;

            CREATE TABLE IF NOT EXISTS LocalIdentity (
                Id INTEGER NOT NULL PRIMARY KEY CHECK (Id = 1),
                Ed25519PrivateKey BLOB NOT NULL,
                Ed25519PublicKey BLOB NOT NULL,
                TlsCertificatePfx BLOB NULL,
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

            CREATE INDEX IF NOT EXISTS IX_SecurityEvents_Timestamp
            ON SecurityEvents (Timestamp DESC);

            CREATE INDEX IF NOT EXISTS IX_SecurityEvents_EventType_Timestamp
            ON SecurityEvents (EventType, Timestamp DESC);

            CREATE INDEX IF NOT EXISTS IX_SecurityEvents_Severity_Timestamp
            ON SecurityEvents (Severity, Timestamp DESC);

            CREATE INDEX IF NOT EXISTS IX_SecurityEvents_PeerDeviceId_Timestamp
            ON SecurityEvents (PeerDeviceId, Timestamp DESC);
            """;
        command.ExecuteNonQuery();

        EnsureColumnExists(connection, "LocalIdentity", "TlsCertificatePfx", "BLOB NULL");
    }

    public SqliteConnection CreateOpenConnection()
    {
        var connection = new SqliteConnection(_connectionString);
        connection.Open();

        using var pragma = connection.CreateCommand();
        pragma.CommandText =
            $"""
            PRAGMA foreign_keys = ON;
            PRAGMA journal_mode = WAL;
            PRAGMA busy_timeout = {BusyTimeoutMs};
            """;
        pragma.ExecuteNonQuery();

        return connection;
    }

    private static void EnsureColumnExists(SqliteConnection connection, string tableName, string columnName, string columnDefinition)
    {
        EnsureSafeSqlIdentifier(tableName, nameof(tableName));
        EnsureSafeSqlIdentifier(columnName, nameof(columnName));
        EnsureSafeColumnDefinition(columnDefinition);

        using var schemaCommand = connection.CreateCommand();
        schemaCommand.CommandText = $"PRAGMA table_info({tableName});";

        using var reader = schemaCommand.ExecuteReader();
        while (reader.Read())
        {
            if (string.Equals(reader["name"] as string, columnName, StringComparison.Ordinal))
            {
                return;
            }
        }

        using var alterCommand = connection.CreateCommand();
        alterCommand.CommandText = $"ALTER TABLE {tableName} ADD COLUMN {columnName} {columnDefinition};";
        alterCommand.ExecuteNonQuery();
    }

    private static void EnsureSafeSqlIdentifier(string identifier, string parameterName)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(identifier, parameterName);

        if (!SqlIdentifierPattern.IsMatch(identifier))
        {
            throw new ArgumentException($"Unsafe SQL identifier '{identifier}'.", parameterName);
        }
    }

    private static void EnsureSafeColumnDefinition(string columnDefinition)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(columnDefinition);

        if (!ColumnDefinitionPattern.IsMatch(columnDefinition) ||
            columnDefinition.Contains(';', StringComparison.Ordinal) ||
            columnDefinition.Contains("--", StringComparison.Ordinal) ||
            columnDefinition.Contains("/*", StringComparison.Ordinal) ||
            columnDefinition.Contains("*/", StringComparison.Ordinal) ||
            columnDefinition.Contains('"', StringComparison.Ordinal) ||
            columnDefinition.Contains('\'', StringComparison.Ordinal))
        {
            throw new ArgumentException($"Unsafe SQL column definition '{columnDefinition}'.", nameof(columnDefinition));
        }
    }
}
