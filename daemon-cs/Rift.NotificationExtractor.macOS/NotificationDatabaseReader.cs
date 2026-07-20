using Microsoft.Data.Sqlite;

namespace Rift.NotificationExtractor.macOS;

internal sealed class NotificationDatabaseReader
{
    private const int MaximumScanRecords = 500;
    private static readonly DateTimeOffset AppleEpoch = new(2001, 1, 1, 0, 0, 0, TimeSpan.Zero);
    private static readonly string[] RequiredAppColumns = ["app_id", "identifier"];
    private static readonly string[] RequiredRecordColumns =
        ["rec_id", "app_id", "uuid", "data", "delivered_date", "presented"];

    private readonly string _databasePath;

    public NotificationDatabaseReader() : this(GetDefaultDatabasePath())
    {
    }

    internal NotificationDatabaseReader(string databasePath)
    {
        _databasePath = databasePath;
    }

    public ExtractorStatus GetStatus()
    {
        if (!File.Exists(_databasePath))
        {
            return new ExtractorStatus { State = "databaseNotFound" };
        }

        try
        {
            using var connection = OpenReadOnly(_databasePath);
            var schemaSupported = HasSupportedSchema(connection);
            return new ExtractorStatus
            {
                DatabaseFound = true,
                DatabaseReadable = true,
                SchemaSupported = schemaSupported,
                State = schemaSupported ? "ready" : "unsupportedSchema"
            };
        }
        catch (SqliteException ex) when (IsAccessDenied(ex))
        {
            return new ExtractorStatus
            {
                DatabaseFound = true,
                State = "fullDiskAccessRequired"
            };
        }
    }

    public NotificationScanResult RescanActiveNotifications() => throw new ExtractorException(
        "activeStateUnavailable",
        "Current macOS Notification Center data does not expose a reliable active-notification set.");

    public NotificationScanResult ScanNotificationChanges(long cursor) => Scan(cursor);

    private NotificationScanResult Scan(long cursor)
    {
        using var snapshot = CreateSnapshot();
        using var connection = OpenReadOnly(snapshot.DatabasePath);
        EnsureSupportedSchema(connection);

        using var command = connection.CreateCommand();
        command.CommandText = """
            SELECT r.rec_id, r.uuid, a.identifier, r.data, r.delivered_date
            FROM record AS r
            INNER JOIN app AS a ON a.app_id = r.app_id
            WHERE r.rec_id > $cursor
            ORDER BY r.rec_id
            LIMIT $limit;
            """;
        command.Parameters.AddWithValue("$limit", MaximumScanRecords);
        command.Parameters.AddWithValue("$cursor", Math.Max(0, cursor));

        var notifications = new List<ExtractedNotification>();
        var skippedRecords = 0;
        var nextCursor = Math.Max(0, cursor);
        using var reader = command.ExecuteReader();
        while (reader.Read())
        {
            var recordId = reader.GetInt64(0);
            nextCursor = Math.Max(nextCursor, recordId);
            try
            {
                var payload = reader.GetFieldValue<byte[]>(3);
                var root = BinaryPropertyListReader.Read(payload);
                var title = FindString(root, "titl", "title");
                var subtitle = FindString(root, "subt", "subtitle");
                var body = FindString(root, "body");
                notifications.Add(new ExtractedNotification
                {
                    NotificationId = GetNotificationId(recordId, reader.GetValue(1)),
                    PackageName = reader.GetString(2),
                    AppName = GetAppName(reader.GetString(2)),
                    Title = NormalizePreview(title, 256),
                    BodyPreview = NormalizePreview(JoinPreview(subtitle, body), 1024),
                    PostedAt = AppleEpoch.AddSeconds(reader.GetDouble(4)).ToUniversalTime().ToString("O"),
                    IsDismissible = false,
                    IsOpenable = false
                });
            }
            catch (Exception ex) when (ex is InvalidDataException or InvalidCastException or OverflowException)
            {
                skippedRecords++;
            }
        }

        return new NotificationScanResult
        {
            Cursor = nextCursor,
            Notifications = notifications,
            SkippedRecords = skippedRecords
        };
    }

    private Snapshot CreateSnapshot()
    {
        if (!File.Exists(_databasePath))
        {
            throw new ExtractorException("databaseNotFound", "The macOS Notification Center database was not found.");
        }

        var directory = Directory.CreateTempSubdirectory("rift-notification-extractor-");
        if (!OperatingSystem.IsWindows())
        {
            File.SetUnixFileMode(directory.FullName,
                UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
        }

        var snapshotPath = Path.Combine(directory.FullName, "notifications.db");
        using (File.Create(snapshotPath))
        {
        }
        if (!OperatingSystem.IsWindows())
        {
            File.SetUnixFileMode(snapshotPath, UnixFileMode.UserRead | UnixFileMode.UserWrite);
        }

        try
        {
            using var source = OpenReadOnly(_databasePath);
            using var destination = new SqliteConnection(new SqliteConnectionStringBuilder
            {
                DataSource = snapshotPath,
                Mode = SqliteOpenMode.ReadWrite,
                Cache = SqliteCacheMode.Private
            }.ToString());
            destination.Open();
            source.BackupDatabase(destination);
            return new Snapshot(directory, snapshotPath);
        }
        catch (SqliteException ex) when (IsAccessDenied(ex))
        {
            directory.Delete(recursive: true);
            throw new ExtractorException(
                "fullDiskAccessRequired",
                "Full Disk Access is required for the Rift Notification Extractor.");
        }
        catch
        {
            directory.Delete(recursive: true);
            throw;
        }
    }

    private static SqliteConnection OpenReadOnly(string path)
    {
        var connection = new SqliteConnection(new SqliteConnectionStringBuilder
        {
            DataSource = path,
            Mode = SqliteOpenMode.ReadOnly,
            Cache = SqliteCacheMode.Private,
            Pooling = false
        }.ToString());
        connection.Open();
        return connection;
    }

    private static bool HasSupportedSchema(SqliteConnection connection) =>
        HasColumns(connection, "app", RequiredAppColumns) &&
        HasColumns(connection, "record", RequiredRecordColumns);

    private static void EnsureSupportedSchema(SqliteConnection connection)
    {
        if (!HasSupportedSchema(connection))
        {
            throw new ExtractorException(
                "unsupportedSchema",
                "The macOS Notification Center database schema is not supported.");
        }
    }

    private static bool HasColumns(SqliteConnection connection, string table, IReadOnlyCollection<string> requiredColumns)
    {
        using var command = connection.CreateCommand();
        command.CommandText = $"PRAGMA table_info({table});";
        using var reader = command.ExecuteReader();
        var columns = new HashSet<string>(StringComparer.Ordinal);
        while (reader.Read())
        {
            columns.Add(reader.GetString(1));
        }
        return requiredColumns.All(columns.Contains);
    }

    private static string GetNotificationId(long recordId, object uuidValue)
    {
        if (uuidValue is byte[] { Length: 16 } bytes)
        {
            return new Guid(bytes, bigEndian: true).ToString("D");
        }
        if (uuidValue is string text && !string.IsNullOrWhiteSpace(text))
        {
            return text.ToLowerInvariant();
        }
        return $"macos-record-{recordId}";
    }

    private static string? FindString(object? value, params string[] keys)
    {
        if (value is Dictionary<string, object?> dictionary)
        {
            foreach (var key in keys)
            {
                if (dictionary.TryGetValue(key, out var candidate) && candidate is string text)
                {
                    return text;
                }
            }
            foreach (var child in dictionary.Values)
            {
                var match = FindString(child, keys);
                if (match is not null)
                {
                    return match;
                }
            }
        }
        else if (value is IEnumerable<object?> values)
        {
            foreach (var child in values)
            {
                var match = FindString(child, keys);
                if (match is not null)
                {
                    return match;
                }
            }
        }
        return null;
    }

    private static string GetAppName(string packageName)
    {
        var component = packageName.Split([':', '.'], StringSplitOptions.RemoveEmptyEntries).LastOrDefault()
            ?? packageName;
        var characters = new List<char>(component.Length + 4);
        for (var index = 0; index < component.Length; index++)
        {
            var character = component[index];
            if (character is '-' or '_')
            {
                characters.Add(' ');
            }
            else
            {
                if (index > 0 && char.IsUpper(character) && char.IsLower(component[index - 1]))
                {
                    characters.Add(' ');
                }
                characters.Add(character);
            }
        }

        var name = new string(characters.ToArray()).Trim();
        if (name.Length == 0)
        {
            return packageName;
        }
        return char.ToUpperInvariant(name[0]) + name[1..];
    }

    private static string? JoinPreview(string? subtitle, string? body)
    {
        var values = new[] { subtitle, body }
            .Where(value => !string.IsNullOrWhiteSpace(value))
            .Select(value => value!.Trim())
            .ToArray();
        return values.Length == 0 ? null : string.Join(" — ", values);
    }

    private static string? NormalizePreview(string? value, int maximumLength)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return null;
        }

        var normalized = new string(value
            .Trim()
            .Select(character => char.IsControl(character) ? ' ' : character)
            .ToArray());
        return normalized.Length <= maximumLength ? normalized : normalized[..maximumLength];
    }

    private static bool IsAccessDenied(SqliteException exception) =>
        exception.SqliteErrorCode is 14 or 23 ||
        exception.Message.Contains("authorization denied", StringComparison.OrdinalIgnoreCase) ||
        exception.Message.Contains("permission denied", StringComparison.OrdinalIgnoreCase);

    private static string GetDefaultDatabasePath() => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
        "Library", "Group Containers", "group.com.apple.usernoted", "db2", "db");

    private sealed class Snapshot(DirectoryInfo directory, string databasePath) : IDisposable
    {
        public string DatabasePath { get; } = databasePath;

        public void Dispose()
        {
            SqliteConnection.ClearAllPools();
            if (directory.Exists)
            {
                directory.Delete(recursive: true);
            }
        }
    }
}

internal sealed class ExtractorException(string code, string message) : Exception(message)
{
    public string Code { get; } = code;
}
