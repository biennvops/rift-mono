using Rift.Daemon.Core.Interfaces;
using StreamJsonRpc;

namespace Rift.Daemon.Core;

public class RiftApiHandler : IRiftApi
{
    private readonly IDaemonInfoService _daemonInfoService;
    private readonly IDiscoveryCoordinator _discoveryCoordinator;
    private readonly IClipboardService _clipboardService;
    private readonly IPairingService _pairingService;

    public RiftApiHandler()
        : this(new UnsupportedDaemonInfoService(), new UnsupportedDiscoveryCoordinator(), new UnsupportedClipboardService(), new UnsupportedPairingService())
    {
    }

    public RiftApiHandler(
        IDaemonInfoService daemonInfoService,
        IDiscoveryCoordinator discoveryCoordinator,
        IClipboardService clipboardService,
        IPairingService pairingService)
    {
        _daemonInfoService = daemonInfoService;
        _discoveryCoordinator = discoveryCoordinator;
        _clipboardService = clipboardService;
        _pairingService = pairingService;
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
    public Task<DiscoveryToggleResult> StartDiscoveryAsync() =>
        Task.FromResult(_discoveryCoordinator.StartDiscovery());

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

    [JsonRpcMethod("rift.startPairing")]
    public Task<StartPairingResult> StartPairingAsync(string deviceId) =>
        Task.FromResult(_pairingService.StartPairing(deviceId));

    [JsonRpcMethod("rift.approvePairing")]
    public Task<ApprovePairingResult> ApprovePairingAsync(string deviceId, string fingerprint) =>
        Task.FromResult(_pairingService.ApprovePairing(deviceId, fingerprint));

    [JsonRpcMethod("rift.rejectPairing")]
    public Task<RejectPairingResult> RejectPairingAsync(string deviceId) =>
        Task.FromResult(_pairingService.RejectPairing(deviceId));

    [JsonRpcMethod("rift.revokeTrust")]
    public Task<RevokeTrustResult> RevokeTrustAsync(string deviceId, string reason) =>
        Task.FromResult(_pairingService.RevokeTrust(deviceId, reason));

    [JsonRpcMethod("rift.unblockPeer")]
    public Task<UnblockPeerResult> UnblockPeerAsync(string deviceId) =>
        Task.FromResult(_pairingService.UnblockPeer(deviceId));

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
            sinceTimestamp = DateTimeOffset.Parse(since);
        }

        return Task.FromResult(_daemonInfoService.QueryEventLog(new SecurityEventQuery
        {
            EventTypes = eventTypes,
            Severities = severities,
            PeerDeviceId = peerDeviceId,
            Since = sinceTimestamp,
            Limit = limit,
            Offset = offset
        }));
    }

    private sealed class UnsupportedDaemonInfoService : IDaemonInfoService
    {
        public DeviceInfoResult GetDeviceInfo() => throw CreateNotConfiguredException();

        public QueryEventLogResult QueryEventLog(SecurityEventQuery query) => throw CreateNotConfiguredException();

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
        public Task BroadcastOfferAsync(string offerId, string contentType, long size, string hash, long expiresInMs, string requiredCapability, long offerSequence) => throw CreateNotConfiguredException();

        public Task HandleOfferReceivedAsync(string deviceId, string payloadSourceDeviceId, string offerId, string contentType, long size, string hash, long expiresInMs, string requiredCapability, long offerSequence) => throw CreateNotConfiguredException();

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

    private sealed class UnsupportedPairingService : IPairingService
    {
        public StartPairingResult StartPairing(string deviceId) => throw CreateNotConfiguredException();

        public ApprovePairingResult ApprovePairing(string deviceId, string fingerprint) => throw CreateNotConfiguredException();

        public RejectPairingResult RejectPairing(string deviceId) => throw CreateNotConfiguredException();

        public RevokeTrustResult RevokeTrust(string deviceId, string reason) => throw CreateNotConfiguredException();

        public UnblockPeerResult UnblockPeer(string deviceId) => throw CreateNotConfiguredException();

        private static LocalRpcException CreateNotConfiguredException()
        {
            return new LocalRpcException("Pairing services are not configured for this IPC host.")
            {
                ErrorCode = -32603
            };
        }
    }
}
