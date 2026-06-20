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
    Task<StartPairingResult> StartPairingAsync(string deviceId);
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
}
