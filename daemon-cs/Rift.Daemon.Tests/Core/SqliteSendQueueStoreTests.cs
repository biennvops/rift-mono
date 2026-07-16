using Microsoft.Data.Sqlite;
using Rift.Daemon.Core.Data;
using Rift.Daemon.Core.Interfaces;

namespace Rift.Daemon.Tests.Core;

public sealed class SqliteSendQueueStoreTests : IDisposable
{
    private readonly string _databasePath;
    private readonly DatabaseContext _databaseContext;
    private readonly SqliteSendQueueStore _store;

    public SqliteSendQueueStoreTests()
    {
        _databasePath = Path.Combine(Path.GetTempPath(), $"rift-send-queue-{Guid.NewGuid():N}.db");
        _databaseContext = new DatabaseContext(_databasePath);
        _databaseContext.Initialize();
        _store = new SqliteSendQueueStore(_databaseContext);
    }

    [Fact]
    public void UpsertAndListItems_RoundTripsQueueItem()
    {
        _store.UpsertItem(new SendQueueItemInfo
        {
            QueueItemId = "queue-1",
            Status = "waiting_for_target",
            LocalPath = "/tmp/demo.txt",
            FileName = "demo.txt",
            MediaType = "text/plain",
            ByteSize = 5,
            CreatedAt = DateTimeOffset.UtcNow.ToString("O"),
            UpdatedAt = DateTimeOffset.UtcNow.ToString("O"),
            Origin = "picker"
        });

        var listed = _store.ListItems();

        var item = Assert.Single(listed);
        Assert.Equal("queue-1", item.QueueItemId);
        Assert.Equal("waiting_for_target", item.Status);
        Assert.Equal("demo.txt", item.FileName);
    }

    [Fact]
    public void DeleteItem_RemovesPersistedQueueItem()
    {
        _store.UpsertItem(new SendQueueItemInfo
        {
            QueueItemId = "queue-1",
            Status = "waiting_for_target",
            LocalPath = "/tmp/demo.txt",
            FileName = "demo.txt",
            MediaType = "text/plain",
            ByteSize = 5,
            CreatedAt = DateTimeOffset.UtcNow.ToString("O"),
            UpdatedAt = DateTimeOffset.UtcNow.ToString("O")
        });

        _store.DeleteItem("queue-1");

        Assert.Empty(_store.ListItems());
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
