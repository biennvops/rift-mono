using Rift.Daemon.Core.Interfaces;

namespace Rift.Daemon.Core;

public interface IRiftApi
{
    Task<string> GetVersionAsync();
    Task<string> GetStatusAsync();
    Task<DeviceInfoResult> GetDeviceInfoAsync();
    Task<ListDiscoveredPeersResult> ListDiscoveredPeersAsync();
    Task<DiscoveryToggleResult> StartDiscoveryAsync();
    Task<DiscoveryToggleResult> StopDiscoveryAsync();
    Task<ListTrustedPeersResult> ListTrustedPeersAsync();
    Task<GetPeerPresenceResult> GetPeerPresenceAsync(string deviceId);
    Task<NotifyClipboardChangeResult> NotifyClipboardChangeAsync(string contentType, long byteSize, string sha256, string contentBase64);
    Task<ListClipboardOffersResult> ListClipboardOffersAsync();
    Task<FetchClipboardContentResult> FetchClipboardContentAsync(string offerId);
    Task<OfferFileResult> OfferFileAsync(string targetDeviceId, string localPath, string? fileName = null, string? mediaType = null);
    Task<EnqueueFileSendResult> EnqueueFileSendAsync(string localPath, string? fileName = null, string? mediaType = null, string? targetDeviceId = null, string? origin = null);
    Task<ListSendQueueResult> ListSendQueueAsync();
    Task<SendQueueItemInfo> GetSendQueueItemAsync(string queueItemId);
    Task<SendQueueItemInfo> AssignSendQueueTargetAsync(string queueItemId, string targetDeviceId);
    Task<SendQueueItemInfo> RetrySendQueueItemAsync(string queueItemId);
    Task<RemoveSendQueueItemResult> RemoveSendQueueItemAsync(string queueItemId);
    Task<ListIncomingFileOffersResult> ListIncomingFileOffersAsync();
    Task<AcceptFileOfferResult> AcceptFileOfferAsync(string transferId, string destinationPath, bool overwrite = false);
    Task<RejectFileOfferResult> RejectFileOfferAsync(string transferId, string failureReason, string? message = null);
    Task<ListFileTransfersResult> ListFileTransfersAsync();
    Task<ListPendingFileCommitsResult> ListPendingFileCommitsAsync();
    Task<ConfirmFileCommitResult> ConfirmFileCommitAsync(string transferId, string destinationPath);
    Task<FailFileCommitResult> FailFileCommitAsync(string transferId, string failureReason, string? message = null);
    Task<StartPairingResult> StartPairingAsync(string deviceId);
    Task<StartPairingResult> StartPairingByEndpointAsync(string address, int port);
    Task<ApprovePairingResult> ApprovePairingAsync(string deviceId, string fingerprint);
    Task<RejectPairingResult> RejectPairingAsync(string deviceId);
    Task<RevokeTrustResult> RevokeTrustAsync(string deviceId, string reason);
    Task<UnblockPeerResult> UnblockPeerAsync(string deviceId);
    Task<QueryEventLogResult> QueryEventLogAsync(
        string[]? eventTypes = null,
        string[]? severities = null,
        string? peerDeviceId = null,
        string? since = null,
        int limit = 100,
        int offset = 0);
    Task<ListOperationsResult> ListOperationsAsync(int limit = 50, int offset = 0);
    Task<OperationRecord> GetOperationAsync(string operationId);
    Task<NotifyLocalNotificationEventResult> NotifyLocalNotificationEventAsync(
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
        Dictionary<string, object?>? icon = null);
    Task<ListNotificationsResult> ListNotificationsAsync();
    Task<PerformNotificationActionResult> PerformNotificationActionAsync(
        string sourceDeviceId,
        string notificationId,
        string action);
    Task<NotificationSyncPolicy> UpdateNotificationSyncPolicyAsync(
        bool enabled,
        string? mode = null,
        string[]? packageNames = null,
        string[]? blacklistedPackages = null);
}
