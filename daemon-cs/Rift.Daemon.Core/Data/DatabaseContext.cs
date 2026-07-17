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
                Ed25519PrivateKey BLOB NULL,
                Ed25519PublicKey BLOB NOT NULL,
                TlsCertificatePfx BLOB NULL,
                CustomDisplayName TEXT NULL,
                CreatedAt TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS Peers (
                DeviceId TEXT NOT NULL PRIMARY KEY,
                DisplayName TEXT NULL,
                Platform TEXT NOT NULL DEFAULT 'unknown',
                Ed25519PublicKey BLOB NULL,
                State TEXT NOT NULL,
                CertificateFingerprint TEXT NULL,
                LastTransition TEXT NOT NULL,
                RevocationEvidence TEXT NULL,
                TrustedEndpointsJson TEXT NULL
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

            CREATE TABLE IF NOT EXISTS SendQueueItems (
                QueueItemId TEXT NOT NULL PRIMARY KEY,
                Status TEXT NOT NULL,
                TargetDeviceId TEXT NULL,
                LocalPath TEXT NOT NULL,
                FileName TEXT NOT NULL,
                MediaType TEXT NOT NULL,
                ByteSize INTEGER NOT NULL,
                CurrentOperationId TEXT NULL,
                LastTransferId TEXT NULL,
                FailureReason TEXT NULL,
                FailureMessage TEXT NULL,
                CreatedAt TEXT NOT NULL,
                UpdatedAt TEXT NOT NULL,
                Origin TEXT NULL
            );

            CREATE INDEX IF NOT EXISTS IX_SecurityEvents_Timestamp
            ON SecurityEvents (Timestamp DESC);

            CREATE INDEX IF NOT EXISTS IX_SecurityEvents_EventType_Timestamp
            ON SecurityEvents (EventType, Timestamp DESC);

            CREATE INDEX IF NOT EXISTS IX_SecurityEvents_Severity_Timestamp
            ON SecurityEvents (Severity, Timestamp DESC);

            CREATE INDEX IF NOT EXISTS IX_SecurityEvents_PeerDeviceId_Timestamp
            ON SecurityEvents (PeerDeviceId, Timestamp DESC);

            CREATE INDEX IF NOT EXISTS IX_SendQueueItems_UpdatedAt
            ON SendQueueItems (UpdatedAt DESC);
            """;
        command.ExecuteNonQuery();

        EnsureColumnExists(connection, "LocalIdentity", "TlsCertificatePfx", "BLOB NULL");
        EnsureColumnExists(connection, "LocalIdentity", "CustomDisplayName", "TEXT NULL");
        EnsureLocalIdentitySecretColumnsNullable(connection);
        EnsureColumnExists(connection, "Peers", "DisplayName", "TEXT NULL");
        EnsureColumnExists(connection, "Peers", "Platform", "TEXT NOT NULL DEFAULT 'unknown'");
        EnsureColumnExists(connection, "Peers", "TrustedEndpointsJson", "TEXT NULL");
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

    private static void EnsureLocalIdentitySecretColumnsNullable(SqliteConnection connection)
    {
        var notNullMap = new Dictionary<string, bool>(StringComparer.Ordinal);

        using (var pragmaCommand = connection.CreateCommand())
        {
            pragmaCommand.CommandText = "PRAGMA table_info(LocalIdentity);";
            using var reader = pragmaCommand.ExecuteReader();
            while (reader.Read())
            {
                var name = reader["name"] as string;
                if (string.IsNullOrWhiteSpace(name))
                {
                    continue;
                }

                notNullMap[name] = Convert.ToInt32(reader["notnull"]) != 0;
            }
        }

        if (!notNullMap.TryGetValue("Ed25519PrivateKey", out var privateKeyNotNull) || !privateKeyNotNull)
        {
            return;
        }

        using var transaction = connection.BeginTransaction();
        using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText =
            """
            ALTER TABLE LocalIdentity RENAME TO LocalIdentity__old;

            CREATE TABLE LocalIdentity (
                Id INTEGER NOT NULL PRIMARY KEY CHECK (Id = 1),
                Ed25519PrivateKey BLOB NULL,
                Ed25519PublicKey BLOB NOT NULL,
                TlsCertificatePfx BLOB NULL,
                CustomDisplayName TEXT NULL,
                CreatedAt TEXT NOT NULL
            );

            INSERT INTO LocalIdentity (Id, Ed25519PrivateKey, Ed25519PublicKey, TlsCertificatePfx, CustomDisplayName, CreatedAt)
            SELECT Id, Ed25519PrivateKey, Ed25519PublicKey, TlsCertificatePfx, CustomDisplayName, CreatedAt
            FROM LocalIdentity__old;

            DROP TABLE LocalIdentity__old;
            """;
        command.ExecuteNonQuery();
        transaction.Commit();
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

        var normalizedColumnDefinition = columnDefinition.Replace("DEFAULT 'unknown'", "DEFAULT unknown", StringComparison.Ordinal);

        if (!ColumnDefinitionPattern.IsMatch(normalizedColumnDefinition) ||
            columnDefinition.Contains(';', StringComparison.Ordinal) ||
            columnDefinition.Contains("--", StringComparison.Ordinal) ||
            columnDefinition.Contains("/*", StringComparison.Ordinal) ||
            columnDefinition.Contains("*/", StringComparison.Ordinal) ||
            (columnDefinition.Contains('\'', StringComparison.Ordinal) &&
             !string.Equals(columnDefinition, "TEXT NOT NULL DEFAULT 'unknown'", StringComparison.Ordinal)) ||
            columnDefinition.Contains('"', StringComparison.Ordinal))
        {
            throw new ArgumentException($"Unsafe SQL column definition '{columnDefinition}'.", nameof(columnDefinition));
        }
    }
}
