using System.Globalization;
using Rift.Daemon.Core.Interfaces;
using Rift.Daemon.Core.Networking;
using StreamJsonRpc;

namespace Rift.Daemon.Core;

public class RiftApiHandler : IRiftApi
{
    private readonly IDaemonInfoService _daemonInfoService;
    private readonly IDiscoveryCoordinator _discoveryCoordinator;
    private readonly IClipboardService _clipboardService;
    private readonly IFileTransferService _fileTransferService;
    private readonly ISendQueueService _sendQueueService;
    private readonly IOperationService _operationService;
    private readonly IPairingService _pairingService;
    private readonly IMediaPlaybackSyncService _mediaPlaybackSyncService;
    private readonly INotificationSyncService _notificationSyncService;
    private readonly IDeviceStatusService _deviceStatusService;

    public RiftApiHandler()
        : this(new UnsupportedDaemonInfoService(), new UnsupportedDiscoveryCoordinator(), new UnsupportedClipboardService(), new UnsupportedFileTransferService(), new UnsupportedSendQueueService(), new UnsupportedOperationService(), new UnsupportedPairingService(), new UnsupportedMediaPlaybackSyncService(), new UnsupportedNotificationSyncService())
    {
    }

    public RiftApiHandler(
        IDaemonInfoService daemonInfoService,
        IDiscoveryCoordinator discoveryCoordinator,
        IClipboardService clipboardService,
        IFileTransferService fileTransferService,
        ISendQueueService sendQueueService,
        IOperationService operationService,
        IPairingService pairingService,
        IMediaPlaybackSyncService mediaPlaybackSyncService,
        INotificationSyncService notificationSyncService,
        IDeviceStatusService? deviceStatusService = null)
    {
        _daemonInfoService = daemonInfoService;
        _discoveryCoordinator = discoveryCoordinator;
        _clipboardService = clipboardService;
        _fileTransferService = fileTransferService;
        _sendQueueService = sendQueueService;
        _operationService = operationService;
        _pairingService = pairingService;
        _mediaPlaybackSyncService = mediaPlaybackSyncService;
        _notificationSyncService = notificationSyncService;
        _deviceStatusService = deviceStatusService ?? new UnsupportedDeviceStatusService();
    }

    public Task<string> GetVersionAsync() => Task.FromResult("0.1-draft");

    public Task<string> GetStatusAsync() => Task.FromResult("daemon-running");

    [JsonRpcMethod("rift.getDeviceInfo")]
    public Task<DeviceInfoResult> GetDeviceInfoAsync() =>
        Task.FromResult(_daemonInfoService.GetDeviceInfo());

    [JsonRpcMethod("rift.listDiscoveredPeers")]
    public Task<ListDiscoveredPeersResult> ListDiscoveredPeersAsync() =>
        Task.FromResult(_daemonInfoService.ListDiscoveredPeers());

    [JsonRpcMethod("rift.startDiscovery")]
    public Task<DiscoveryToggleResult> StartDiscoveryAsync()
    {
        try
        {
            return Task.FromResult(_discoveryCoordinator.StartDiscovery());
        }
        catch (LocalNetworkAccessDeniedException ex)
        {
            throw new LocalRpcException(ex.Message)
            {
                ErrorCode = -32010,
                ErrorData = new Dictionary<string, object?>
                {
                    ["policy"] = "local_network",
                    ["action"] = "startDiscovery"
                }
            };
        }
    }

    [JsonRpcMethod("rift.stopDiscovery")]
    public Task<DiscoveryToggleResult> StopDiscoveryAsync() =>
        Task.FromResult(_discoveryCoordinator.StopDiscovery());

    [JsonRpcMethod("rift.listTrustedPeers")]
    public Task<ListTrustedPeersResult> ListTrustedPeersAsync() =>
        Task.FromResult(_daemonInfoService.ListTrustedPeers());

    [JsonRpcMethod("rift.getPeerPresence")]
    public Task<GetPeerPresenceResult> GetPeerPresenceAsync(string deviceId)
    {
        try
        {
            return Task.FromResult(_daemonInfoService.GetPeerPresence(deviceId));
        }
        catch (InvalidOperationException ex)
        {
            throw new LocalRpcException(ex.Message) { ErrorCode = -32009 };
        }
        catch (UnauthorizedAccessException ex)
        {
            throw new LocalRpcException(ex.Message) { ErrorCode = -32004 };
        }
    }

    [JsonRpcMethod("rift.notifyClipboardChange")]
    public async Task<NotifyClipboardChangeResult> NotifyClipboardChangeAsync(string contentType, long byteSize, string sha256, string contentBase64)
    {
        try
        {
            return await _clipboardService.NotifyClipboardChangeAsync(contentType, byteSize, sha256, contentBase64, CancellationToken.None);
        }
        catch (ClipboardFailureException ex)
        {
            throw new LocalRpcException(ex.Message) { ErrorCode = ex.ErrorCode };
        }
    }

    [JsonRpcMethod("rift.listClipboardOffers")]
    public Task<ListClipboardOffersResult> ListClipboardOffersAsync() =>
        _clipboardService.ListClipboardOffersAsync();

    [JsonRpcMethod("rift.fetchClipboardContent")]
    public async Task<FetchClipboardContentResult> FetchClipboardContentAsync(string offerId)
    {
        try
        {
            return await _clipboardService.FetchClipboardContentAsync(offerId, CancellationToken.None);
        }
        catch (ClipboardFailureException ex)
        {
            throw new LocalRpcException(ex.Message) { ErrorCode = ex.ErrorCode };
        }
    }

    [JsonRpcMethod("rift.offerFile")]
    public async Task<OfferFileResult> OfferFileAsync(string targetDeviceId, string localPath, string? fileName = null, string? mediaType = null)
    {
        try
        {
            return await _fileTransferService.OfferFileAsync(targetDeviceId, localPath, fileName, mediaType, CancellationToken.None);
        }
        catch (FileTransferFailureException ex)
        {
            throw new LocalRpcException(ex.Message) { ErrorCode = ex.ErrorCode };
        }
    }

    [JsonRpcMethod("rift.enqueueFileSend")]
    public async Task<EnqueueFileSendResult> EnqueueFileSendAsync(string localPath, string? fileName = null, string? mediaType = null, string? targetDeviceId = null, string? origin = null)
    {
        try
        {
            return await _sendQueueService.EnqueueFileSendAsync(localPath, fileName, mediaType, targetDeviceId, origin, CancellationToken.None);
        }
        catch (SendQueueFailureException ex)
        {
            throw new LocalRpcException(ex.Message) { ErrorCode = ex.ErrorCode };
        }
    }

    [JsonRpcMethod("rift.listSendQueue")]
    public Task<ListSendQueueResult> ListSendQueueAsync() =>
        _sendQueueService.ListSendQueueAsync(CancellationToken.None);

    [JsonRpcMethod("rift.getSendQueueItem")]
    public async Task<SendQueueItemInfo> GetSendQueueItemAsync(string queueItemId)
    {
        try
        {
            return await _sendQueueService.GetSendQueueItemAsync(queueItemId, CancellationToken.None);
        }
        catch (SendQueueFailureException ex)
        {
            throw new LocalRpcException(ex.Message) { ErrorCode = ex.ErrorCode };
        }
    }

    [JsonRpcMethod("rift.assignSendQueueTarget")]
    public async Task<SendQueueItemInfo> AssignSendQueueTargetAsync(string queueItemId, string targetDeviceId)
    {
        try
        {
            return await _sendQueueService.AssignSendQueueTargetAsync(queueItemId, targetDeviceId, CancellationToken.None);
        }
        catch (SendQueueFailureException ex)
        {
            throw new LocalRpcException(ex.Message) { ErrorCode = ex.ErrorCode };
        }
    }

    [JsonRpcMethod("rift.retrySendQueueItem")]
    public async Task<SendQueueItemInfo> RetrySendQueueItemAsync(string queueItemId)
    {
        try
        {
            return await _sendQueueService.RetrySendQueueItemAsync(queueItemId, CancellationToken.None);
        }
        catch (SendQueueFailureException ex)
        {
            throw new LocalRpcException(ex.Message) { ErrorCode = ex.ErrorCode };
        }
    }

    [JsonRpcMethod("rift.removeSendQueueItem")]
    public async Task<RemoveSendQueueItemResult> RemoveSendQueueItemAsync(string queueItemId)
    {
        try
        {
            return await _sendQueueService.RemoveSendQueueItemAsync(queueItemId, CancellationToken.None);
        }
        catch (SendQueueFailureException ex)
        {
            throw new LocalRpcException(ex.Message) { ErrorCode = ex.ErrorCode };
        }
    }

    [JsonRpcMethod("rift.cancelFileTransfer")]
    public async Task<CancelFileTransferResult> CancelFileTransferAsync(string transferId)
    {
        try
        {
            var info = await _fileTransferService.CancelTransferAsync(transferId, CancellationToken.None);
            return new CancelFileTransferResult
            {
                TransferId = info.TransferId,
                Cancelled = true
            };
        }
        catch (FileTransferFailureException ex)
        {
            throw new LocalRpcException(ex.Message) { ErrorCode = ex.ErrorCode };
        }
    }

    [JsonRpcMethod("rift.listIncomingFileOffers")]
    public Task<ListIncomingFileOffersResult> ListIncomingFileOffersAsync() =>
        _fileTransferService.ListIncomingFileOffersAsync();

    [JsonRpcMethod("rift.acceptFileOffer")]
    public async Task<AcceptFileOfferResult> AcceptFileOfferAsync(string transferId, string destinationPath, bool overwrite = false)
    {
        try
        {
            return await _fileTransferService.AcceptFileOfferAsync(transferId, destinationPath, overwrite, CancellationToken.None);
        }
        catch (FileTransferFailureException ex)
        {
            throw new LocalRpcException(ex.Message) { ErrorCode = ex.ErrorCode };
        }
    }

    [JsonRpcMethod("rift.rejectFileOffer")]
    public async Task<RejectFileOfferResult> RejectFileOfferAsync(string transferId, string failureReason, string? message = null)
    {
        try
        {
            return await _fileTransferService.RejectFileOfferAsync(transferId, failureReason, message, CancellationToken.None);
        }
        catch (FileTransferFailureException ex)
        {
            throw new LocalRpcException(ex.Message) { ErrorCode = ex.ErrorCode };
        }
    }

    [JsonRpcMethod("rift.listFileTransfers")]
    public Task<ListFileTransfersResult> ListFileTransfersAsync() =>
        _fileTransferService.ListFileTransfersAsync();

    [JsonRpcMethod("rift.listPendingFileCommits")]
    public Task<ListPendingFileCommitsResult> ListPendingFileCommitsAsync() =>
        _fileTransferService.ListPendingFileCommitsAsync();

    [JsonRpcMethod("rift.confirmFileCommit")]
    public async Task<ConfirmFileCommitResult> ConfirmFileCommitAsync(string transferId, string destinationPath)
    {
        try
        {
            return await _fileTransferService.ConfirmFileCommitAsync(transferId, destinationPath, CancellationToken.None);
        }
        catch (FileTransferFailureException ex)
        {
            throw new LocalRpcException(ex.Message) { ErrorCode = ex.ErrorCode };
        }
    }

    [JsonRpcMethod("rift.failFileCommit")]
    public async Task<FailFileCommitResult> FailFileCommitAsync(string transferId, string failureReason, string? message = null)
    {
        try
        {
            return await _fileTransferService.FailFileCommitAsync(transferId, failureReason, message, CancellationToken.None);
        }
        catch (FileTransferFailureException ex)
        {
            throw new LocalRpcException(ex.Message) { ErrorCode = ex.ErrorCode };
        }
    }

    [JsonRpcMethod("rift.startPairing")]
    public Task<StartPairingResult> StartPairingAsync(string deviceId) =>
        ExecutePairingAsync(() => _pairingService.StartPairingAsync(deviceId));

    [JsonRpcMethod("rift.startPairingByEndpoint")]
    public Task<StartPairingResult> StartPairingByEndpointAsync(string address, int port) =>
        ExecutePairingAsync(() => _pairingService.StartPairingByEndpointAsync(address, port));

    [JsonRpcMethod("rift.approvePairing")]
    public Task<ApprovePairingResult> ApprovePairingAsync(string deviceId, string fingerprint) =>
        ExecutePairingAsync(() => _pairingService.ApprovePairingAsync(deviceId, fingerprint));

    [JsonRpcMethod("rift.rejectPairing")]
    public Task<RejectPairingResult> RejectPairingAsync(string deviceId) =>
        ExecutePairingAsync(() => _pairingService.RejectPairingAsync(deviceId));

    [JsonRpcMethod("rift.revokeTrust")]
    public Task<RevokeTrustResult> RevokeTrustAsync(string deviceId, string reason) =>
        ExecutePairingAsync(() => _pairingService.RevokeTrustAsync(deviceId, reason));

    [JsonRpcMethod("rift.unblockPeer")]
    public Task<UnblockPeerResult> UnblockPeerAsync(string deviceId) =>
        ExecutePairingAsync(() => _pairingService.UnblockPeerAsync(deviceId));

    [JsonRpcMethod("rift.resetRevokedPeer")]
    public Task<ResetRevokedPeerResult> ResetRevokedPeerAsync(string deviceId) =>
        ExecutePairingAsync(() => _pairingService.ResetRevokedPeerAsync(deviceId));

    [JsonRpcMethod("rift.queryEventLog")]
    public Task<QueryEventLogResult> QueryEventLogAsync(
        string[]? eventTypes = null,
        string[]? severities = null,
        string? peerDeviceId = null,
        string? since = null,
        int limit = 100,
        int offset = 0)
    {
        DateTimeOffset? sinceTimestamp = null;
        if (!string.IsNullOrWhiteSpace(since))
        {
            if (!DateTimeOffset.TryParse(
                    since,
                    CultureInfo.InvariantCulture,
                    DateTimeStyles.RoundtripKind,
                    out var parsedSince))
            {
                throw new LocalRpcException($"Invalid 'since' timestamp '{since}'. Expected an RFC 3339 / ISO 8601 timestamp.")
                {
                    ErrorCode = -32602
                };
            }

            sinceTimestamp = parsedSince;
        }

        return _daemonInfoService.QueryEventLogAsync(new SecurityEventQuery
        {
            EventTypes = eventTypes,
            Severities = severities,
            PeerDeviceId = peerDeviceId,
            Since = sinceTimestamp,
            Limit = limit,
            Offset = offset
        });
    }

    [JsonRpcMethod("rift.listOperations")]
    public Task<ListOperationsResult> ListOperationsAsync(int limit = 50, int offset = 0) =>
        Task.FromResult(_operationService.ListOperations(limit, offset));

    [JsonRpcMethod("rift.getOperation")]
    public Task<OperationRecord> GetOperationAsync(string operationId)
    {
        try
        {
            return Task.FromResult(_operationService.GetOperation(operationId));
        }
        catch (InvalidOperationException ex)
        {
            throw new LocalRpcException(ex.Message) { ErrorCode = -32009 };
        }
    }

    [JsonRpcMethod("rift.listNotifications")]
    public Task<ListNotificationsResult> ListNotificationsAsync() =>
        _notificationSyncService.ListNotificationsAsync(CancellationToken.None);

    [JsonRpcMethod("rift.listMediaPlayback")]
    public Task<ListMediaPlaybackResult> ListMediaPlaybackAsync() =>
        _mediaPlaybackSyncService.ListMediaPlaybackAsync(CancellationToken.None);

    [JsonRpcMethod("rift.getPeerDeviceStatus")]
    public Task<DeviceStatusRecord> GetPeerDeviceStatusAsync(string deviceId)
    {
        var peer = _daemonInfoService.ListTrustedPeers().Peers.FirstOrDefault(candidate =>
            string.Equals(candidate.DeviceId, deviceId, StringComparison.Ordinal));
        if (peer is null)
        {
            throw new LocalRpcException($"Peer '{deviceId}' was not found.") { ErrorCode = -32009 };
        }
        if (!string.Equals(peer.TrustState, "trusted", StringComparison.Ordinal))
        {
            throw new LocalRpcException("Peer is not trusted.") { ErrorCode = -32004 };
        }

        var status = _deviceStatusService.GetDeviceStatus(deviceId);
        return status is null
            ? throw new LocalRpcException($"Device status for '{deviceId}' is unavailable.") { ErrorCode = -32009 }
            : Task.FromResult(status);
    }

    [JsonRpcMethod("rift.notifyLocalDeviceStatus")]
    public async Task<NotifyLocalDeviceStatusResult> NotifyLocalDeviceStatusAsync(
        bool? batteryPresent = null,
        int? batteryPercent = null,
        string? chargingState = null,
        string? powerSource = null,
        bool? lowPowerMode = null,
        string? observedAt = null,
        string? sourcePlatform = null)
    {
        try
        {
            return await _deviceStatusService.UpdateLocalStatusAsync(new DeviceStatusRecord
            {
                SourceDeviceId = _daemonInfoService.GetDeviceInfo().DeviceId,
                SourcePlatform = sourcePlatform ?? _daemonInfoService.GetDeviceInfo().Platform,
                BatteryPresent = batteryPresent,
                BatteryPercent = batteryPercent,
                ChargingState = chargingState,
                PowerSource = powerSource,
                LowPowerMode = lowPowerMode,
                ObservedAt = observedAt ?? DateTimeOffset.UtcNow.ToString("O")
            }, CancellationToken.None).ConfigureAwait(false);
        }
        catch (ArgumentException ex)
        {
            throw new LocalRpcException(ex.Message) { ErrorCode = -32602 };
        }
    }

    [JsonRpcMethod("rift.getMediaPlayback")]
    public async Task<MediaPlaybackRecord> GetMediaPlaybackAsync(string sourceDeviceId, string playbackId)
    {
        try
        {
            return await _mediaPlaybackSyncService.GetMediaPlaybackAsync(sourceDeviceId, playbackId, CancellationToken.None);
        }
        catch (MediaPlaybackSyncFailureException ex)
        {
            throw new LocalRpcException(ex.Message) { ErrorCode = ex.ErrorCode };
        }
    }

    [JsonRpcMethod("rift.notifyLocalMediaPlaybackEvent")]
    public async Task<NotifyLocalMediaPlaybackEventResult> NotifyLocalMediaPlaybackEventAsync(
        string eventType,
        string playbackId,
        string? appId = null,
        string? appName = null,
        string? title = null,
        string? artist = null,
        string? album = null,
        string? playbackState = null,
        long? positionMs = null,
        long? durationMs = null,
        bool? canPlay = null,
        bool? canPause = null,
        bool? canSkipNext = null,
        bool? canSkipPrevious = null,
        bool? canSeek = null,
        string? updatedAt = null,
        string? sourcePlatform = null,
        string? removedAt = null)
    {
        try
        {
            return await _mediaPlaybackSyncService.HandleLocalPlaybackEventAsync(
                eventType,
                new MediaPlaybackRecord
                {
                    PlaybackId = playbackId,
                    SourceDeviceId = _daemonInfoService.GetDeviceInfo().DeviceId,
                    SourcePlatform = sourcePlatform,
                    AppId = appId ?? string.Empty,
                    AppName = appName ?? string.Empty,
                    Title = title,
                    Artist = artist,
                    Album = album,
                    PlaybackState = playbackState ?? string.Empty,
                    PositionMs = positionMs ?? 0,
                    DurationMs = durationMs,
                    CanPlay = canPlay ?? false,
                    CanPause = canPause ?? false,
                    CanSkipNext = canSkipNext ?? false,
                    CanSkipPrevious = canSkipPrevious ?? false,
                    CanSeek = canSeek ?? false,
                    UpdatedAt = updatedAt ?? string.Empty
                },
                removedAt,
                CancellationToken.None);
        }
        catch (MediaPlaybackSyncFailureException ex)
        {
            throw new LocalRpcException(ex.Message) { ErrorCode = ex.ErrorCode };
        }
    }

    [JsonRpcMethod("rift.performMediaPlaybackAction")]
    public async Task<PerformMediaPlaybackActionResult> PerformMediaPlaybackActionAsync(string sourceDeviceId, string playbackId, string action, long? positionMs = null)
    {
        try
        {
            return await _mediaPlaybackSyncService.PerformMediaPlaybackActionAsync(sourceDeviceId, playbackId, action, positionMs, CancellationToken.None);
        }
        catch (MediaPlaybackSyncFailureException ex)
        {
            throw new LocalRpcException(ex.Message) { ErrorCode = ex.ErrorCode };
        }
    }

    [JsonRpcMethod("rift.reportLocalMediaPlaybackActionHandled")]
    public async Task<ReportHandledMediaPlaybackActionResult> ReportLocalMediaPlaybackActionHandledAsync(
        string requestId,
        bool success,
        string? failureReason = null,
        string? message = null)
    {
        try
        {
            return await _mediaPlaybackSyncService.ReportHandledMediaPlaybackActionAsync(
                requestId,
                success,
                failureReason,
                message,
                CancellationToken.None);
        }
        catch (MediaPlaybackSyncFailureException ex)
        {
            throw new LocalRpcException(ex.Message) { ErrorCode = ex.ErrorCode };
        }
    }

    [JsonRpcMethod("rift.notifyLocalNotificationEvent")]
    public async Task<NotifyLocalNotificationEventResult> NotifyLocalNotificationEventAsync(
        string eventType,
        string notificationId,
        string? packageName = null,
        string? appName = null,
        string? title = null,
        string? bodyPreview = null,
        string? postedAt = null,
        bool? isDismissible = null,
        bool? isOpenable = null,
        string? sourcePlatform = null,
        string? removedAt = null,
        Dictionary<string, object?>? icon = null)
    {
        try
        {
            return await _notificationSyncService.HandleLocalNotificationEventAsync(
                eventType,
                new NotificationSyncRecord
                {
                    NotificationId = notificationId,
                    SourceDeviceId = _daemonInfoService.GetDeviceInfo().DeviceId,
                    SourcePlatform = sourcePlatform,
                    PackageName = packageName ?? string.Empty,
                    AppName = appName ?? string.Empty,
                    Title = title,
                    BodyPreview = bodyPreview,
                    PostedAt = postedAt ?? string.Empty,
                    IsDismissible = isDismissible ?? false,
                    IsOpenable = isOpenable ?? false,
                    Icon = icon
                },
                removedAt,
                CancellationToken.None);
        }
        catch (NotificationSyncFailureException ex)
        {
            throw new LocalRpcException(ex.Message) { ErrorCode = ex.ErrorCode };
        }
    }

    [JsonRpcMethod("rift.performNotificationAction")]
    public async Task<PerformNotificationActionResult> PerformNotificationActionAsync(
        string sourceDeviceId,
        string notificationId,
        string action)
    {
        try
        {
            return await _notificationSyncService.PerformNotificationActionAsync(
                sourceDeviceId,
                notificationId,
                action,
                CancellationToken.None);
        }
        catch (NotificationSyncFailureException ex)
        {
            throw new LocalRpcException(ex.Message) { ErrorCode = ex.ErrorCode };
        }
    }

    [JsonRpcMethod("rift.reportLocalNotificationActionHandled")]
    public async Task<ReportHandledNotificationActionResult> ReportLocalNotificationActionHandledAsync(
        string requestId,
        bool success,
        string? failureReason = null,
        string? message = null)
    {
        try
        {
            return await _notificationSyncService.ReportHandledNotificationActionAsync(
                requestId,
                success,
                failureReason,
                message,
                CancellationToken.None);
        }
        catch (NotificationSyncFailureException ex)
        {
            throw new LocalRpcException(ex.Message) { ErrorCode = ex.ErrorCode };
        }
    }

    [JsonRpcMethod("rift.updateNotificationSyncPolicy")]
    public async Task<NotificationSyncPolicy> UpdateNotificationSyncPolicyAsync(
        bool enabled,
        string? mode = null,
        string[]? packageNames = null,
        string[]? blacklistedPackages = null)
    {
        try
        {
            var hasCanonicalMode = mode is not null;
            var hasCanonicalPackageNames = packageNames is not null;
            var hasLegacyPackages = blacklistedPackages is not null;
            if (hasLegacyPackages && (hasCanonicalMode || hasCanonicalPackageNames))
            {
                throw new NotificationSyncFailureException(
                    "Canonical and legacy notification sync policy fields cannot be mixed.",
                    -32602);
            }

            if (hasCanonicalMode != hasCanonicalPackageNames)
            {
                throw new NotificationSyncFailureException(
                    "Notification sync policy requires both mode and packageNames.",
                    -32602);
            }

            string canonicalMode;
            IReadOnlyList<string> canonicalPackageNames;
            if (hasLegacyPackages)
            {
                canonicalPackageNames = NotificationSyncPolicyModes.NormalizePackageNames(blacklistedPackages!);
                canonicalMode = canonicalPackageNames.Count == 0
                    ? NotificationSyncPolicyModes.All
                    : NotificationSyncPolicyModes.Exclude;
            }
            else if (hasCanonicalMode)
            {
                canonicalMode = NotificationSyncPolicyModes.Validate(mode);
                canonicalPackageNames = NotificationSyncPolicyModes.NormalizePackageNames(packageNames!);
            }
            else
            {
                throw new NotificationSyncFailureException(
                    "Notification sync policy requires canonical or legacy package fields.",
                    -32602);
            }

            return await _notificationSyncService.UpdateNotificationSyncPolicyAsync(
                enabled,
                canonicalMode,
                canonicalPackageNames,
                CancellationToken.None).ConfigureAwait(false);
        }
        catch (NotificationSyncFailureException ex)
        {
            throw new LocalRpcException(ex.Message) { ErrorCode = ex.ErrorCode };
        }
        catch (ArgumentException ex)
        {
            throw new LocalRpcException(ex.Message) { ErrorCode = -32602 };
        }
    }

    private static async Task<TResult> ExecutePairingAsync<TResult>(Func<Task<TResult>> action)
    {
        try
        {
            return await action();
        }
        catch (LocalRpcException)
        {
            throw;
        }
        catch (Exception ex)
        {
            throw new LocalRpcException(ex.Message)
            {
                ErrorCode = -32603
            };
        }
    }

    private sealed class UnsupportedDaemonInfoService : IDaemonInfoService
    {
        public DeviceInfoResult GetDeviceInfo() => throw CreateNotConfiguredException();

        public Task<QueryEventLogResult> QueryEventLogAsync(SecurityEventQuery query) => throw CreateNotConfiguredException();

        public ListTrustedPeersResult ListTrustedPeers() => throw CreateNotConfiguredException();

        public ListDiscoveredPeersResult ListDiscoveredPeers() => throw CreateNotConfiguredException();

        public GetPeerPresenceResult GetPeerPresence(string deviceId) => throw CreateNotConfiguredException();

        private static LocalRpcException CreateNotConfiguredException()
        {
            return new LocalRpcException("Daemon info services are not configured for this IPC host.")
            {
                ErrorCode = -32603
            };
        }
    }

    private sealed class UnsupportedDiscoveryCoordinator : IDiscoveryCoordinator
    {
        public DiscoveryToggleResult StartDiscovery() => throw CreateNotConfiguredException();

        public DiscoveryToggleResult StopDiscovery() => throw CreateNotConfiguredException();

        public ListDiscoveredPeersResult ListDiscoveredPeers() => throw CreateNotConfiguredException();

        public bool TryGetDiscoveredPeer(string deviceId, out DiscoveredPeerInfo? peer)
        {
            peer = null;
            throw CreateNotConfiguredException();
        }

        private static LocalRpcException CreateNotConfiguredException()
        {
            return new LocalRpcException("Discovery services are not configured for this IPC host.")
            {
                ErrorCode = -32603
            };
        }
    }

    private sealed class UnsupportedClipboardService : IClipboardService
    {
        public Task<string[]> BroadcastOfferAsync(string offerId, string contentType, long size, string hash, long expiresInMs, string requiredCapability, long offerSequence) => throw CreateNotConfiguredException();

        public Task HandleOfferReceivedAsync(ReceivedClipboardOffer offer) => throw CreateNotConfiguredException();

        public Task<byte[]> FetchContentAsync(string deviceId, string offerId) => throw CreateNotConfiguredException();

        public Task<NotifyClipboardChangeResult> NotifyClipboardChangeAsync(string contentType, long byteSize, string sha256, string contentBase64, CancellationToken cancellationToken) => throw CreateNotConfiguredException();

        public Task<ListClipboardOffersResult> ListClipboardOffersAsync() => throw CreateNotConfiguredException();

        public Task<FetchClipboardContentResult> FetchClipboardContentAsync(string offerId, CancellationToken cancellationToken) => throw CreateNotConfiguredException();

        public Task HandleFetchRequestAsync(string deviceId, string offerId, string requestingDeviceId, CancellationToken cancellationToken) => throw CreateNotConfiguredException();

        public Task HandleFetchResponseAsync(string deviceId, string offerId, string contentBase64, long byteSize, string sha256, CancellationToken cancellationToken) => throw CreateNotConfiguredException();

        public Task HandleFetchRejectAsync(string deviceId, string offerId, string failureReason, string? message, CancellationToken cancellationToken) => throw CreateNotConfiguredException();

        private static LocalRpcException CreateNotConfiguredException()
        {
            return new LocalRpcException("Clipboard services are not configured for this IPC host.")
            {
                ErrorCode = -32603
            };
        }
    }

    private sealed class UnsupportedFileTransferService : IFileTransferService
    {
        public event EventHandler<FileTransferLifecycleEventArgs>? TransferUpdated
        {
            add { }
            remove { }
        }

        public Task<OfferFileResult> OfferFileAsync(string targetDeviceId, string localPath, string? fileName, string? mediaType, CancellationToken cancellationToken) => throw CreateNotConfiguredException();
        public Task<ListIncomingFileOffersResult> ListIncomingFileOffersAsync() => throw CreateNotConfiguredException();
        public Task<AcceptFileOfferResult> AcceptFileOfferAsync(string transferId, string destinationPath, bool overwrite, CancellationToken cancellationToken) => throw CreateNotConfiguredException();
        public Task<RejectFileOfferResult> RejectFileOfferAsync(string transferId, string failureReason, string? message, CancellationToken cancellationToken) => throw CreateNotConfiguredException();
        public Task<ListFileTransfersResult> ListFileTransfersAsync() => throw CreateNotConfiguredException();
        public Task<ListPendingFileCommitsResult> ListPendingFileCommitsAsync() => throw CreateNotConfiguredException();
        public Task<ConfirmFileCommitResult> ConfirmFileCommitAsync(string transferId, string destinationPath, CancellationToken cancellationToken) => throw CreateNotConfiguredException();
        public Task<FailFileCommitResult> FailFileCommitAsync(string transferId, string failureReason, string? message, CancellationToken cancellationToken) => throw CreateNotConfiguredException();
        public Task<FileTransferInfo> CancelTransferAsync(string transferId, CancellationToken cancellationToken) => throw CreateNotConfiguredException();
        public Task HandleOfferReceivedAsync(ReceivedFileOffer offer, CancellationToken cancellationToken) => throw CreateNotConfiguredException();
        public Task HandleAcceptReceivedAsync(string deviceId, string transferId, string receivingDeviceId, int? chunkSize, CancellationToken cancellationToken) => throw CreateNotConfiguredException();
        public Task HandleRejectReceivedAsync(string deviceId, string transferId, string failureReason, string? message, CancellationToken cancellationToken) => throw CreateNotConfiguredException();
        public Task HandleChunkReceivedAsync(string deviceId, string transferId, int chunkIndex, long offset, int byteSize, string chunkSha256, string contentBase64, bool isLastChunk, CancellationToken cancellationToken) => throw CreateNotConfiguredException();
        public Task HandleCompleteReceivedAsync(string deviceId, string transferId, long byteSize, string sha256, int chunkCount, CancellationToken cancellationToken) => throw CreateNotConfiguredException();
        public Task HandleCommittedReceivedAsync(string deviceId, string transferId, long byteSize, string sha256, CancellationToken cancellationToken) => throw CreateNotConfiguredException();
        public Task HandleCancelReceivedAsync(string deviceId, string transferId, string failureReason, string? message, CancellationToken cancellationToken) => throw CreateNotConfiguredException();
        public Task HandleResumeReceivedAsync(string deviceId, string transferId, string receivingDeviceId, int nextChunkIndex, long offset, CancellationToken cancellationToken) => throw CreateNotConfiguredException();

        private static LocalRpcException CreateNotConfiguredException()
        {
            return new LocalRpcException("File transfer services are not configured for this IPC host.")
            {
                ErrorCode = -32603
            };
        }
    }

    private sealed class UnsupportedSendQueueService : ISendQueueService
    {
        public Task<EnqueueFileSendResult> EnqueueFileSendAsync(string localPath, string? fileName, string? mediaType, string? targetDeviceId, string? origin, CancellationToken cancellationToken) => throw CreateNotConfiguredException();
        public Task<ListSendQueueResult> ListSendQueueAsync(CancellationToken cancellationToken) => throw CreateNotConfiguredException();
        public Task<SendQueueItemInfo> GetSendQueueItemAsync(string queueItemId, CancellationToken cancellationToken) => throw CreateNotConfiguredException();
        public Task<SendQueueItemInfo> AssignSendQueueTargetAsync(string queueItemId, string targetDeviceId, CancellationToken cancellationToken) => throw CreateNotConfiguredException();
        public Task<SendQueueItemInfo> RetrySendQueueItemAsync(string queueItemId, CancellationToken cancellationToken) => throw CreateNotConfiguredException();
        public Task<RemoveSendQueueItemResult> RemoveSendQueueItemAsync(string queueItemId, CancellationToken cancellationToken) => throw CreateNotConfiguredException();

        private static LocalRpcException CreateNotConfiguredException()
        {
            return new LocalRpcException("Send queue services are not configured for this IPC host.")
            {
                ErrorCode = -32603
            };
        }
    }

    private sealed class UnsupportedPairingService : IPairingService
    {
        public Task<StartPairingResult> StartPairingAsync(string deviceId) => throw CreateNotConfiguredException();

        public Task<StartPairingResult> StartPairingByEndpointAsync(string address, int port) => throw CreateNotConfiguredException();

        public Task<ApprovePairingResult> ApprovePairingAsync(string deviceId, string fingerprint) => throw CreateNotConfiguredException();

        public Task<RejectPairingResult> RejectPairingAsync(string deviceId) => throw CreateNotConfiguredException();

        public Task<RevokeTrustResult> RevokeTrustAsync(string deviceId, string reason) => throw CreateNotConfiguredException();

        public Task<UnblockPeerResult> UnblockPeerAsync(string deviceId) => throw CreateNotConfiguredException();

        public Task<ResetRevokedPeerResult> ResetRevokedPeerAsync(string deviceId) => throw CreateNotConfiguredException();

        private static LocalRpcException CreateNotConfiguredException()
        {
            return new LocalRpcException("Pairing services are not configured for this IPC host.")
            {
                ErrorCode = -32603
            };
        }
    }

    private sealed class UnsupportedOperationService : IOperationService
    {
        public OperationRecord CreateOperation(string operationId, string operationType, string sourceDeviceId, string destinationDeviceId) => throw CreateNotConfiguredException();

        public OperationRecord TransitionOperation(string operationId, OperationState nextState, string? failureReason = null, IReadOnlyDictionary<string, object?>? details = null) => throw CreateNotConfiguredException();

        public ListOperationsResult ListOperations(int limit = 50, int offset = 0) => throw CreateNotConfiguredException();

        public OperationRecord GetOperation(string operationId) => throw CreateNotConfiguredException();

        private static LocalRpcException CreateNotConfiguredException()
        {
            return new LocalRpcException("Operation services are not configured for this IPC host.")
            {
                ErrorCode = -32603
            };
        }
    }

    private sealed class UnsupportedDeviceStatusService : IDeviceStatusService
    {
        public Task<NotifyLocalDeviceStatusResult> UpdateLocalStatusAsync(DeviceStatusRecord status, CancellationToken cancellationToken) => throw CreateNotConfiguredException();
        public Task HandlePeerStatusUpdatedAsync(DeviceStatusRecord status, CancellationToken cancellationToken) => throw CreateNotConfiguredException();
        public Task SendPeerErrorAsync(string peerDeviceId, string failureReason, string? refMessageId, string message, CancellationToken cancellationToken) => throw CreateNotConfiguredException();
        public DeviceStatusRecord? GetDeviceStatus(string sourceDeviceId) => throw CreateNotConfiguredException();

        private static LocalRpcException CreateNotConfiguredException()
        {
            return new LocalRpcException("Device status services are not configured for this IPC host.")
            {
                ErrorCode = -32603
            };
        }
    }

    private sealed class UnsupportedNotificationSyncService : INotificationSyncService
    {
        public Task<ListNotificationsResult> ListNotificationsAsync(CancellationToken cancellationToken) => throw CreateNotConfiguredException();

        public Task<NotifyLocalNotificationEventResult> HandleLocalNotificationEventAsync(string eventType, NotificationSyncRecord notification, string? removedAt, CancellationToken cancellationToken) => throw CreateNotConfiguredException();

        public Task<PerformNotificationActionResult> PerformNotificationActionAsync(string sourceDeviceId, string notificationId, string action, CancellationToken cancellationToken) => throw CreateNotConfiguredException();

        public Task<NotificationSyncPolicy> UpdateNotificationSyncPolicyAsync(bool enabled, string mode, IReadOnlyList<string> packageNames, CancellationToken cancellationToken) => throw CreateNotConfiguredException();

        public Task HandleNotificationPostedAsync(NotificationSyncRecord notification, CancellationToken cancellationToken) => throw CreateNotConfiguredException();

        public Task HandleNotificationUpdatedAsync(NotificationSyncRecord notification, CancellationToken cancellationToken) => throw CreateNotConfiguredException();

        public Task HandleNotificationRemovedAsync(NotificationRemovedRecord notification, CancellationToken cancellationToken) => throw CreateNotConfiguredException();

        public Task HandleNotificationActionResultAsync(NotificationActionResultRecord result, CancellationToken cancellationToken) => throw CreateNotConfiguredException();

        public Task HandleNotificationActionRequestAsync(NotificationActionRequestRecord request, CancellationToken cancellationToken) => throw CreateNotConfiguredException();

        public Task<ReportHandledNotificationActionResult> ReportHandledNotificationActionAsync(string requestId, bool success, string? failureReason, string? message, CancellationToken cancellationToken) => throw CreateNotConfiguredException();

        private static LocalRpcException CreateNotConfiguredException()
        {
            return new LocalRpcException("Notification sync services are not configured for this IPC host.")
            {
                ErrorCode = -32603
            };
        }
    }

    private sealed class UnsupportedMediaPlaybackSyncService : IMediaPlaybackSyncService
    {
        public Task<NotifyLocalMediaPlaybackEventResult> HandleLocalPlaybackEventAsync(string eventType, MediaPlaybackRecord playback, string? removedAt, CancellationToken cancellationToken) => throw CreateNotConfiguredException();
        public Task PublishLocalPlaybackToPeerAsync(string peerDeviceId, MediaPlaybackRecord playback, CancellationToken cancellationToken) => throw CreateNotConfiguredException();
        public Task SendPeerErrorAsync(string peerDeviceId, string failureReason, string? refMessageId, string message, CancellationToken cancellationToken) => throw CreateNotConfiguredException();
        public Task<ListMediaPlaybackResult> ListMediaPlaybackAsync(CancellationToken cancellationToken) => throw CreateNotConfiguredException();
        public Task<MediaPlaybackRecord> GetMediaPlaybackAsync(string sourceDeviceId, string playbackId, CancellationToken cancellationToken) => throw CreateNotConfiguredException();
        public Task<PerformMediaPlaybackActionResult> PerformMediaPlaybackActionAsync(string sourceDeviceId, string playbackId, string action, long? positionMs, CancellationToken cancellationToken) => throw CreateNotConfiguredException();
        public Task HandleMediaPlaybackPostedAsync(MediaPlaybackRecord playback, CancellationToken cancellationToken) => throw CreateNotConfiguredException();
        public Task HandleMediaPlaybackUpdatedAsync(MediaPlaybackRecord playback, CancellationToken cancellationToken) => throw CreateNotConfiguredException();
        public Task HandleMediaPlaybackRemovedAsync(MediaPlaybackRemovedRecord playback, CancellationToken cancellationToken) => throw CreateNotConfiguredException();
        public Task HandleMediaPlaybackActionResultAsync(MediaPlaybackActionResultRecord result, CancellationToken cancellationToken) => throw CreateNotConfiguredException();
        public Task HandleMediaPlaybackActionRequestAsync(MediaPlaybackActionRequestRecord request, CancellationToken cancellationToken) => throw CreateNotConfiguredException();
        public Task<ReportHandledMediaPlaybackActionResult> ReportHandledMediaPlaybackActionAsync(string requestId, bool success, string? failureReason, string? message, CancellationToken cancellationToken) => throw CreateNotConfiguredException();

        private static LocalRpcException CreateNotConfiguredException()
        {
            return new LocalRpcException("Media playback sync services are not configured for this IPC host.")
            {
                ErrorCode = -32603
            };
        }
    }
}
