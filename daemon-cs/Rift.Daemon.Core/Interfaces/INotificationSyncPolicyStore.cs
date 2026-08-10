namespace Rift.Daemon.Core.Interfaces;

public interface INotificationSyncPolicyStore
{
    NotificationSyncPolicy Load();

    void Save(NotificationSyncPolicy policy);
}
