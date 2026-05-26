using Rift.Daemon.Windows.Models;

namespace Rift.Daemon.Windows.Interfaces;

public interface IEventBus
{
    Task PublishAsync(RiftEvent ev);
    IAsyncEnumerable<RiftEvent> SubscribeAsync();
}
