namespace Rift.Daemon.Core.Interfaces;

public interface ISendQueueStore
{
    IReadOnlyList<SendQueueItemInfo> ListItems();

    void UpsertItem(SendQueueItemInfo item);

    void DeleteItem(string queueItemId);
}
