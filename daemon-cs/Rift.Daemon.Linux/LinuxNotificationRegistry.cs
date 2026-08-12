namespace Rift.Daemon.Linux;

internal sealed record LinuxNotificationTarget(
    string RiftNotificationId,
    string NotificationServerOwner,
    uint NativeNotificationId);

internal sealed class LinuxNotificationRegistry
{
    private readonly Lock _gate = new();
    private readonly Dictionary<string, Entry> _targets = new(StringComparer.Ordinal);

    public void Register(LinuxNotificationTarget target)
    {
        ArgumentNullException.ThrowIfNull(target);
        lock (_gate)
        {
            var isClosing = _targets.TryGetValue(target.RiftNotificationId, out var existing) &&
                existing.IsClosing &&
                existing.Target == target;
            _targets[target.RiftNotificationId] = new Entry(target, isClosing);
        }
    }

    public bool TryGet(string riftNotificationId, out LinuxNotificationTarget? target)
    {
        lock (_gate)
        {
            if (_targets.TryGetValue(riftNotificationId, out var entry) && !entry.IsClosing)
            {
                target = entry.Target;
                return true;
            }
        }

        target = null;
        return false;
    }

    public bool TryBeginClosing(string riftNotificationId, out LinuxNotificationTarget? target)
    {
        lock (_gate)
        {
            if (!_targets.TryGetValue(riftNotificationId, out var entry) || entry.IsClosing)
            {
                target = null;
                return false;
            }

            _targets[riftNotificationId] = entry with { IsClosing = true };
            target = entry.Target;
            return true;
        }
    }

    public bool RestoreActive(LinuxNotificationTarget target)
    {
        ArgumentNullException.ThrowIfNull(target);
        lock (_gate)
        {
            if (!_targets.TryGetValue(target.RiftNotificationId, out var entry) ||
                !entry.IsClosing ||
                entry.Target != target)
            {
                return false;
            }

            _targets[target.RiftNotificationId] = entry with { IsClosing = false };
            return true;
        }
    }

    public bool Remove(string riftNotificationId)
    {
        lock (_gate)
        {
            return _targets.Remove(riftNotificationId);
        }
    }

    private sealed record Entry(LinuxNotificationTarget Target, bool IsClosing);
}
