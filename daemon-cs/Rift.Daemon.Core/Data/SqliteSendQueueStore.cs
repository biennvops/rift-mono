using Microsoft.Data.Sqlite;
using Rift.Daemon.Core.Interfaces;

namespace Rift.Daemon.Core.Data;

public sealed class SqliteSendQueueStore(DatabaseContext databaseContext) : ISendQueueStore
{
    public IReadOnlyList<SendQueueItemInfo> ListItems()
    {
        using var connection = databaseContext.CreateOpenConnection();
        using var command = connection.CreateCommand();
        command.CommandText =
            """
            SELECT QueueItemId, Status, TargetDeviceId, LocalPath, FileName, MediaType,
                   ByteSize, CurrentOperationId, LastTransferId, FailureReason,
                   FailureMessage, CreatedAt, UpdatedAt, Origin
            FROM SendQueueItems
            ORDER BY UpdatedAt DESC, QueueItemId DESC;
            """;

        var items = new List<SendQueueItemInfo>();
        using var reader = command.ExecuteReader();
        while (reader.Read())
        {
            items.Add(ReadItem(reader));
        }

        return items;
    }

    public void UpsertItem(SendQueueItemInfo item)
    {
        ArgumentNullException.ThrowIfNull(item);

        using var connection = databaseContext.CreateOpenConnection();
        using var command = connection.CreateCommand();
        command.CommandText =
            """
            INSERT INTO SendQueueItems (
                QueueItemId, Status, TargetDeviceId, LocalPath, FileName, MediaType,
                ByteSize, CurrentOperationId, LastTransferId, FailureReason,
                FailureMessage, CreatedAt, UpdatedAt, Origin
            )
            VALUES (
                $queueItemId, $status, $targetDeviceId, $localPath, $fileName, $mediaType,
                $byteSize, $currentOperationId, $lastTransferId, $failureReason,
                $failureMessage, $createdAt, $updatedAt, $origin
            )
            ON CONFLICT(QueueItemId) DO UPDATE SET
                Status = excluded.Status,
                TargetDeviceId = excluded.TargetDeviceId,
                LocalPath = excluded.LocalPath,
                FileName = excluded.FileName,
                MediaType = excluded.MediaType,
                ByteSize = excluded.ByteSize,
                CurrentOperationId = excluded.CurrentOperationId,
                LastTransferId = excluded.LastTransferId,
                FailureReason = excluded.FailureReason,
                FailureMessage = excluded.FailureMessage,
                CreatedAt = excluded.CreatedAt,
                UpdatedAt = excluded.UpdatedAt,
                Origin = excluded.Origin;
            """;
        BindItem(command, item);
        command.ExecuteNonQuery();
    }

    public void DeleteItem(string queueItemId)
    {
        using var connection = databaseContext.CreateOpenConnection();
        using var command = connection.CreateCommand();
        command.CommandText = "DELETE FROM SendQueueItems WHERE QueueItemId = $queueItemId;";
        command.Parameters.AddWithValue("$queueItemId", queueItemId);
        command.ExecuteNonQuery();
    }

    private static SendQueueItemInfo ReadItem(SqliteDataReader reader)
    {
        return new SendQueueItemInfo
        {
            QueueItemId = (string)reader["QueueItemId"],
            Status = (string)reader["Status"],
            TargetDeviceId = reader["TargetDeviceId"] as string,
            LocalPath = (string)reader["LocalPath"],
            FileName = (string)reader["FileName"],
            MediaType = (string)reader["MediaType"],
            ByteSize = (long)reader["ByteSize"],
            CurrentOperationId = reader["CurrentOperationId"] as string,
            LastTransferId = reader["LastTransferId"] as string,
            FailureReason = reader["FailureReason"] as string,
            FailureMessage = reader["FailureMessage"] as string,
            CreatedAt = (string)reader["CreatedAt"],
            UpdatedAt = (string)reader["UpdatedAt"],
            Origin = reader["Origin"] as string
        };
    }

    private static void BindItem(SqliteCommand command, SendQueueItemInfo item)
    {
        command.Parameters.AddWithValue("$queueItemId", item.QueueItemId);
        command.Parameters.AddWithValue("$status", item.Status);
        command.Parameters.AddWithValue("$targetDeviceId", (object?)item.TargetDeviceId ?? DBNull.Value);
        command.Parameters.AddWithValue("$localPath", item.LocalPath);
        command.Parameters.AddWithValue("$fileName", item.FileName);
        command.Parameters.AddWithValue("$mediaType", item.MediaType);
        command.Parameters.AddWithValue("$byteSize", item.ByteSize);
        command.Parameters.AddWithValue("$currentOperationId", (object?)item.CurrentOperationId ?? DBNull.Value);
        command.Parameters.AddWithValue("$lastTransferId", (object?)item.LastTransferId ?? DBNull.Value);
        command.Parameters.AddWithValue("$failureReason", (object?)item.FailureReason ?? DBNull.Value);
        command.Parameters.AddWithValue("$failureMessage", (object?)item.FailureMessage ?? DBNull.Value);
        command.Parameters.AddWithValue("$createdAt", item.CreatedAt);
        command.Parameters.AddWithValue("$updatedAt", item.UpdatedAt);
        command.Parameters.AddWithValue("$origin", (object?)item.Origin ?? DBNull.Value);
    }
}
