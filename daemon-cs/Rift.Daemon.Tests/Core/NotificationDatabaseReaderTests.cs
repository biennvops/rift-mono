using System.Runtime.Versioning;
using Microsoft.Data.Sqlite;
using Rift.NotificationExtractor.macOS;

namespace Rift.Daemon.Tests.Core;

[SupportedOSPlatform("macos13.0")]
public sealed class NotificationDatabaseReaderTests : IDisposable
{
    private const string PayloadBase64 =
        "YnBsaXN0MDDRAQJTcmVx0wMEBQYHCFRib2R5VHN1YnRUdGl0bF8QEkFsbCBjaGVja3MgcGFzc2VkLldSaWZ0IENJXkJ1aWxkIGNvbXBsZXRlCAsPFhsgJTpCAAAAAAAAAQEAAAAAAAAACQAAAAAAAAAAAAAAAAAAAFE=";

    private readonly string _tempDirectory = Directory.CreateTempSubdirectory("rift-notification-extractor-test-").FullName;

    [Fact]
    public void GetStatus_ReportsSupportedFixture()
    {
        var databasePath = CreateDatabase();
        var reader = new NotificationDatabaseReader(databasePath);

        var status = reader.GetStatus();

        Assert.True(status.DatabaseFound);
        Assert.True(status.DatabaseReadable);
        Assert.True(status.SchemaSupported);
        Assert.Equal("ready", status.State);
    }

    [Fact]
    public void RescanActiveNotifications_ReturnsNormalizedPreviewSafeRecords()
    {
        var notificationId = Guid.Parse("67aa580e-6062-4cc0-a3c0-8cb53a9fcf7f");
        var databasePath = CreateDatabase();
        InsertNotification(databasePath, 1, notificationId, presented: true, Convert.FromBase64String(PayloadBase64));
        InsertNotification(databasePath, 2, Guid.NewGuid(), presented: false, Convert.FromBase64String(PayloadBase64));
        var reader = new NotificationDatabaseReader(databasePath);

        var result = reader.RescanActiveNotifications();

        var notification = Assert.Single(result.Notifications);
        Assert.Equal(notificationId.ToString("D"), notification.NotificationId);
        Assert.Equal("com.example.build", notification.PackageName);
        Assert.Equal("Build", notification.AppName);
        Assert.Equal("Build complete", notification.Title);
        Assert.Equal("Rift CI — All checks passed.", notification.BodyPreview);
        Assert.Equal("2001-01-01T00:01:00.0000000+00:00", notification.PostedAt);
        Assert.False(notification.IsDismissible);
        Assert.False(notification.IsOpenable);
        Assert.Equal(1, result.Cursor);
        Assert.Equal(0, result.SkippedRecords);
    }

    [Fact]
    public void ScanNotificationChanges_UsesMonotonicRecordCursorAndSkipsMalformedPayloads()
    {
        var databasePath = CreateDatabase();
        InsertNotification(databasePath, 1, Guid.NewGuid(), presented: true, Convert.FromBase64String(PayloadBase64));
        InsertNotification(databasePath, 2, Guid.NewGuid(), presented: true, "not a plist"u8.ToArray());
        InsertNotification(databasePath, 3, Guid.NewGuid(), presented: true, Convert.FromBase64String(PayloadBase64));
        var reader = new NotificationDatabaseReader(databasePath);

        var result = reader.ScanNotificationChanges(1);

        var notification = Assert.Single(result.Notifications);
        Assert.Equal("Build complete", notification.Title);
        Assert.Equal(3, result.Cursor);
        Assert.Equal(1, result.SkippedRecords);
    }

    [Fact]
    public void GetStatus_FailsClosedForUnknownSchema()
    {
        var databasePath = Path.Combine(_tempDirectory, "unsupported.db");
        using (var connection = Open(databasePath))
        {
            using var command = connection.CreateCommand();
            command.CommandText = "CREATE TABLE record (rec_id INTEGER PRIMARY KEY);";
            command.ExecuteNonQuery();
        }
        var reader = new NotificationDatabaseReader(databasePath);

        var status = reader.GetStatus();

        Assert.True(status.DatabaseReadable);
        Assert.False(status.SchemaSupported);
        Assert.Equal("unsupportedSchema", status.State);
        Assert.Throws<ExtractorException>(() => reader.RescanActiveNotifications());
    }

    private string CreateDatabase()
    {
        var databasePath = Path.Combine(_tempDirectory, $"{Guid.NewGuid():N}.db");
        using var connection = Open(databasePath);
        using var command = connection.CreateCommand();
        command.CommandText = """
            CREATE TABLE app (
                app_id INTEGER PRIMARY KEY,
                identifier TEXT NOT NULL
            );
            CREATE TABLE record (
                rec_id INTEGER PRIMARY KEY,
                app_id INTEGER NOT NULL,
                uuid BLOB NOT NULL,
                data BLOB NOT NULL,
                delivered_date REAL NOT NULL,
                presented INTEGER NOT NULL
            );
            INSERT INTO app (app_id, identifier) VALUES (1, 'com.example.build');
            """;
        command.ExecuteNonQuery();
        return databasePath;
    }

    private static void InsertNotification(
        string databasePath,
        long recordId,
        Guid notificationId,
        bool presented,
        byte[] payload)
    {
        using var connection = Open(databasePath);
        using var command = connection.CreateCommand();
        command.CommandText = """
            INSERT INTO record (rec_id, app_id, uuid, data, delivered_date, presented)
            VALUES ($recordId, 1, $uuid, $data, 60, $presented);
            """;
        command.Parameters.AddWithValue("$recordId", recordId);
        command.Parameters.AddWithValue("$uuid", notificationId.ToByteArray(bigEndian: true));
        command.Parameters.AddWithValue("$data", payload);
        command.Parameters.AddWithValue("$presented", presented ? 1 : 0);
        command.ExecuteNonQuery();
    }

    private static SqliteConnection Open(string databasePath)
    {
        var connection = new SqliteConnection($"Data Source={databasePath};Pooling=False");
        connection.Open();
        return connection;
    }

    public void Dispose()
    {
        SqliteConnection.ClearAllPools();
        if (Directory.Exists(_tempDirectory))
        {
            Directory.Delete(_tempDirectory, recursive: true);
        }
    }
}
