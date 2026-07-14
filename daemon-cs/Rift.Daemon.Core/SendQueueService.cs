using System.Collections.Concurrent;
using Rift.Daemon.Core.Interfaces;

namespace Rift.Daemon.Core;

public sealed class SendQueueService : ISendQueueService
{
    private readonly ConcurrentDictionary<string, MutableSendQueueItem> _items = new(StringComparer.Ordinal);
    private readonly List<string> _itemOrder = [];
    private readonly Lock _lock = new();
    private readonly ITrustStore _trustStore;
    private readonly IIpcNotificationService? _ipcNotificationService;
    private readonly IFileTransferService? _fileTransferService;
    private readonly ITransport? _transport;
    private readonly ISendQueueStore? _store;

    public SendQueueService(
        ITrustStore trustStore,
        IIpcNotificationService? ipcNotificationService = null,
        IFileTransferService? fileTransferService = null,
        ITransport? transport = null,
        ISendQueueStore? store = null)
    {
        _trustStore = trustStore;
        _ipcNotificationService = ipcNotificationService;
        _fileTransferService = fileTransferService;
        _transport = transport;
        _store = store;

        if (_fileTransferService is not null)
        {
            _fileTransferService.TransferUpdated += OnTransferUpdated;
        }

        if (_transport is not null)
        {
            _transport.SessionStateChanged += OnSessionStateChanged;
        }

        RestorePersistedItems();
    }

    public async Task<EnqueueFileSendResult> EnqueueFileSendAsync(
        string localPath,
        string? fileName,
        string? mediaType,
        string? targetDeviceId,
        string? origin,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        ValidateSourcePath(localPath);
        ValidateTargetIfProvided(targetDeviceId);

        var queueItemId = Guid.NewGuid().ToString("D");
        var now = DateTimeOffset.UtcNow;
        var item = new MutableSendQueueItem
        {
            QueueItemId = queueItemId,
            Status = string.IsNullOrWhiteSpace(targetDeviceId) ? "waiting_for_target" : "queued",
            TargetDeviceId = string.IsNullOrWhiteSpace(targetDeviceId) ? null : targetDeviceId,
            LocalPath = localPath,
            FileName = string.IsNullOrWhiteSpace(fileName) ? Path.GetFileName(localPath) : fileName!,
            MediaType = string.IsNullOrWhiteSpace(mediaType) ? "application/octet-stream" : mediaType!,
            ByteSize = new FileInfo(localPath).Length,
            CreatedAt = now,
            UpdatedAt = now,
            Origin = string.IsNullOrWhiteSpace(origin) ? null : origin
        };

        lock (_lock)
        {
            _items[queueItemId] = item;
            _itemOrder.Add(queueItemId);
        }

        NotifyQueueItemUpdated(item);
        PersistItem(item);
        await TryDispatchItemAsync(item.QueueItemId, cancellationToken).ConfigureAwait(false);
        return new EnqueueFileSendResult
        {
            QueueItemId = queueItemId,
            Status = GetRequiredItem(queueItemId).Status,
            TargetDeviceId = GetRequiredItem(queueItemId).TargetDeviceId
        };
    }

    public Task<ListSendQueueResult> ListSendQueueAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        List<SendQueueItemInfo> items;
        lock (_lock)
        {
            items = _itemOrder
                .Where(id => _items.TryGetValue(id, out _))
                .Select(id => _items[id].ToInfo())
                .ToList();
        }

        return Task.FromResult(new ListSendQueueResult { Items = items });
    }

    public Task<SendQueueItemInfo> GetSendQueueItemAsync(string queueItemId, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        return Task.FromResult(GetRequiredItem(queueItemId).ToInfo());
    }

    public async Task<SendQueueItemInfo> AssignSendQueueTargetAsync(
        string queueItemId,
        string targetDeviceId,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        ValidateTargetIfProvided(targetDeviceId);

        var item = GetRequiredItem(queueItemId);
        lock (_lock)
        {
            item.TargetDeviceId = targetDeviceId;
            item.Status = "queued";
            item.FailureReason = null;
            item.FailureMessage = null;
            item.UpdatedAt = DateTimeOffset.UtcNow;
        }

        NotifyQueueItemUpdated(item);
        PersistItem(item);
        await TryDispatchItemAsync(queueItemId, cancellationToken).ConfigureAwait(false);
        return GetRequiredItem(queueItemId).ToInfo();
    }

    public async Task<SendQueueItemInfo> RetrySendQueueItemAsync(string queueItemId, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var item = GetRequiredItem(queueItemId);
        lock (_lock)
        {
            if (string.IsNullOrWhiteSpace(item.TargetDeviceId))
            {
                item.Status = "waiting_for_target";
            }
            else
            {
                ValidateTargetIfProvided(item.TargetDeviceId);
                item.Status = "queued";
            }

            item.FailureReason = null;
            item.FailureMessage = null;
            item.UpdatedAt = DateTimeOffset.UtcNow;
        }

        NotifyQueueItemUpdated(item);
        PersistItem(item);
        await TryDispatchItemAsync(queueItemId, cancellationToken).ConfigureAwait(false);
        return GetRequiredItem(queueItemId).ToInfo();
    }

    public Task<RemoveSendQueueItemResult> RemoveSendQueueItemAsync(string queueItemId, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var removed = false;
        lock (_lock)
        {
            removed = _items.TryRemove(queueItemId, out _);
            if (removed)
            {
                _itemOrder.Remove(queueItemId);
            }
        }

        if (!removed)
        {
            throw new SendQueueFailureException("NotFound", -32009, $"Send queue item '{queueItemId}' was not found.");
        }

        _ = _ipcNotificationService?.NotifyAsync("rift.onSendQueueChanged", new
        {
            queueItemId,
            removed = true
        }, CancellationToken.None);
        _store?.DeleteItem(queueItemId);

        return Task.FromResult(new RemoveSendQueueItemResult
        {
            QueueItemId = queueItemId,
            Removed = true
        });
    }

    private MutableSendQueueItem GetRequiredItem(string queueItemId)
    {
        if (string.IsNullOrWhiteSpace(queueItemId))
        {
            throw new SendQueueFailureException("NotFound", -32009, "Send queue item ID is required.");
        }

        lock (_lock)
        {
            if (_items.TryGetValue(queueItemId, out var item))
            {
                return item;
            }
        }

        throw new SendQueueFailureException("NotFound", -32009, $"Send queue item '{queueItemId}' was not found.");
    }

    private void ValidateSourcePath(string localPath)
    {
        if (string.IsNullOrWhiteSpace(localPath))
        {
            throw new SendQueueFailureException("InvalidPath", -32602, "localPath is required.");
        }

        if (!File.Exists(localPath))
        {
            throw new SendQueueFailureException("NotFound", -32009, $"Source file '{localPath}' was not found.");
        }
    }

    private void ValidateTargetIfProvided(string? targetDeviceId)
    {
        if (string.IsNullOrWhiteSpace(targetDeviceId))
        {
            return;
        }

        var peer = _trustStore.GetPeer(targetDeviceId);
        if (peer is null)
        {
            throw new SendQueueFailureException("NotFound", -32009, $"Trusted peer '{targetDeviceId}' was not found.");
        }

        if (peer.State != TrustState.Trusted)
        {
            throw new SendQueueFailureException("Unauthorized", -32004, $"Peer '{targetDeviceId}' is not trusted.");
        }
    }

    private void NotifyQueueItemUpdated(MutableSendQueueItem item)
    {
        _ = _ipcNotificationService?.NotifyAsync("rift.onSendQueueItemUpdated", new
        {
            queueItemId = item.QueueItemId,
            status = item.Status,
            targetDeviceId = item.TargetDeviceId,
            currentOperationId = item.CurrentOperationId,
            lastTransferId = item.LastTransferId,
            failureReason = item.FailureReason,
            failureMessage = item.FailureMessage
        }, CancellationToken.None);
    }

    private void RestorePersistedItems()
    {
        var store = _store;
        if (store is null)
        {
            return;
        }

        foreach (var persisted in store.ListItems())
        {
            var item = MutableSendQueueItem.FromInfo(persisted);
            NormalizeRestoredItem(item);
            lock (_lock)
            {
                _items[item.QueueItemId] = item;
                _itemOrder.Add(item.QueueItemId);
            }
            PersistItem(item);
        }
    }

    private void NormalizeRestoredItem(MutableSendQueueItem item)
    {
        if (!File.Exists(item.LocalPath))
        {
            item.Status = "failed";
            item.FailureReason = "NotFound";
            item.FailureMessage = $"Source file '{item.LocalPath}' was not found.";
            item.CurrentOperationId = null;
            item.LastTransferId = null;
            item.UpdatedAt = DateTimeOffset.UtcNow;
            return;
        }

        item.ByteSize = new FileInfo(item.LocalPath).Length;
        if (item.Status is "dispatching" or "sending")
        {
            item.CurrentOperationId = null;
            item.LastTransferId = null;
            item.Status = string.IsNullOrWhiteSpace(item.TargetDeviceId)
                ? "waiting_for_target"
                : "waiting_for_peer";
            item.FailureReason = "DaemonRestarted";
            item.FailureMessage = "Queued send will resume when the target device is available.";
            item.UpdatedAt = DateTimeOffset.UtcNow;
        }
    }

    private void PersistItem(MutableSendQueueItem item)
    {
        _store?.UpsertItem(item.ToInfo());
    }

    private async Task TryDispatchItemAsync(string queueItemId, CancellationToken cancellationToken)
    {
        if (_fileTransferService is null)
        {
            return;
        }

        MutableSendQueueItem item;
        lock (_lock)
        {
            item = GetRequiredItem(queueItemId);
            if (string.IsNullOrWhiteSpace(item.TargetDeviceId))
            {
                item.Status = "waiting_for_target";
                item.UpdatedAt = DateTimeOffset.UtcNow;
                return;
            }

            if (item.Status is "dispatching" or "sending" or "sent")
            {
                return;
            }

            item.Status = "dispatching";
            item.FailureReason = null;
            item.FailureMessage = null;
            item.UpdatedAt = DateTimeOffset.UtcNow;
        }

        NotifyQueueItemUpdated(item);
        PersistItem(item);

        try
        {
            var result = await _fileTransferService.OfferFileAsync(
                item.TargetDeviceId!,
                item.LocalPath,
                item.FileName,
                item.MediaType,
                cancellationToken).ConfigureAwait(false);

            lock (_lock)
            {
                if (_items.TryGetValue(queueItemId, out var current))
                {
                    current.LastTransferId = result.TransferId;
                    current.CurrentOperationId = result.OperationId;
                    current.Status = "dispatching";
                    current.FailureReason = null;
                    current.FailureMessage = null;
                    current.UpdatedAt = DateTimeOffset.UtcNow;
                    item = current;
                }
            }

            NotifyQueueItemUpdated(item);
            PersistItem(item);
        }
        catch (Exception ex) when (ex is FileTransferFailureException or InvalidOperationException or UnauthorizedAccessException or IOException)
        {
            lock (_lock)
            {
                if (_items.TryGetValue(queueItemId, out var current))
                {
                    ApplyDispatchFailure(current, ex);
                    item = current;
                }
            }

            NotifyQueueItemUpdated(item);
            PersistItem(item);
        }
    }

    private void ApplyDispatchFailure(MutableSendQueueItem item, Exception ex)
    {
        var reason = ex switch
        {
            FileTransferFailureException failure => failure.FailureReason,
            UnauthorizedAccessException => "PolicyDenied",
            IOException => "StorageUnavailable",
            _ => "PeerUnreachable"
        };

        item.CurrentOperationId = null;
        item.LastTransferId = null;
        item.FailureReason = reason;
        item.FailureMessage = ex.Message;
        item.Status = IsRecoverableFailureReason(reason) ? "waiting_for_peer" : "failed";
        item.UpdatedAt = DateTimeOffset.UtcNow;
    }

    private static bool IsRecoverableFailureReason(string? failureReason)
    {
        return failureReason is "PeerUnreachable" or "ConnectionLost" or "Timeout";
    }

    private void OnTransferUpdated(object? sender, FileTransferLifecycleEventArgs args)
    {
        if (!string.Equals(args.Direction, "outgoing", StringComparison.Ordinal))
        {
            return;
        }

        MutableSendQueueItem? updated = null;
        lock (_lock)
        {
            updated = _items.Values.FirstOrDefault(item =>
                string.Equals(item.LastTransferId, args.TransferId, StringComparison.Ordinal) ||
                string.Equals(item.CurrentOperationId, args.OperationId, StringComparison.Ordinal));
            if (updated is null)
            {
                return;
            }

            updated.LastTransferId = args.TransferId;
            updated.CurrentOperationId = args.OperationId;
            updated.UpdatedAt = DateTimeOffset.UtcNow;
            switch (args.State)
            {
                case "active":
                    updated.Status = "sending";
                    updated.FailureReason = null;
                    updated.FailureMessage = null;
                    break;
                case "done":
                    updated.Status = "sent";
                    updated.FailureReason = null;
                    updated.FailureMessage = null;
                    break;
                case "failed":
                    updated.FailureReason = args.FailureReason;
                    updated.FailureMessage = args.Message;
                    updated.Status = IsRecoverableFailureReason(args.FailureReason)
                        ? "waiting_for_peer"
                        : "failed";
                    if (updated.Status == "waiting_for_peer")
                    {
                        updated.CurrentOperationId = null;
                        updated.LastTransferId = null;
                    }
                    break;
            }
        }

        NotifyQueueItemUpdated(updated);
        PersistItem(updated);
    }

    private void OnSessionStateChanged(object? sender, SessionStateChangedEventArgs args)
    {
        if (!args.IsOnline)
        {
            return;
        }

        var queueItemIds = new List<string>();
        lock (_lock)
        {
            foreach (var item in _items.Values)
            {
                if (!string.Equals(item.TargetDeviceId, args.PeerDeviceId, StringComparison.Ordinal))
                {
                    continue;
                }

                if (item.Status is "queued" or "waiting_for_peer")
                {
                    queueItemIds.Add(item.QueueItemId);
                }
            }
        }

        foreach (var queueItemId in queueItemIds)
        {
            _ = Task.Run(() => TryDispatchItemAsync(queueItemId, CancellationToken.None));
        }
    }

    private sealed class MutableSendQueueItem
    {
        public string QueueItemId { get; init; } = string.Empty;
        public string Status { get; set; } = string.Empty;
        public string? TargetDeviceId { get; set; }
        public string LocalPath { get; init; } = string.Empty;
        public string FileName { get; init; } = string.Empty;
        public string MediaType { get; init; } = string.Empty;
        public long ByteSize { get; set; }
        public string? CurrentOperationId { get; set; }
        public string? LastTransferId { get; set; }
        public string? FailureReason { get; set; }
        public string? FailureMessage { get; set; }
        public DateTimeOffset CreatedAt { get; init; }
        public DateTimeOffset UpdatedAt { get; set; }
        public string? Origin { get; init; }

        public SendQueueItemInfo ToInfo() => new()
        {
            QueueItemId = QueueItemId,
            Status = Status,
            TargetDeviceId = TargetDeviceId,
            LocalPath = LocalPath,
            FileName = FileName,
            MediaType = MediaType,
            ByteSize = ByteSize,
            CurrentOperationId = CurrentOperationId,
            LastTransferId = LastTransferId,
            FailureReason = FailureReason,
            FailureMessage = FailureMessage,
            CreatedAt = CreatedAt.ToString("O"),
            UpdatedAt = UpdatedAt.ToString("O"),
            Origin = Origin
        };

        public static MutableSendQueueItem FromInfo(SendQueueItemInfo item)
        {
            return new MutableSendQueueItem
            {
                QueueItemId = item.QueueItemId,
                Status = item.Status,
                TargetDeviceId = item.TargetDeviceId,
                LocalPath = item.LocalPath,
                FileName = item.FileName,
                MediaType = item.MediaType,
                ByteSize = item.ByteSize,
                CurrentOperationId = item.CurrentOperationId,
                LastTransferId = item.LastTransferId,
                FailureReason = item.FailureReason,
                FailureMessage = item.FailureMessage,
                CreatedAt = DateTimeOffset.Parse(item.CreatedAt),
                UpdatedAt = DateTimeOffset.Parse(item.UpdatedAt),
                Origin = item.Origin
            };
        }
    }
}
