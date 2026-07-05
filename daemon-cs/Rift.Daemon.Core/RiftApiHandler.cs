using System.Globalization;
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
        public Task BroadcastOfferAsync(string offerId, string contentType, long size, string hash, long expiresInMs, string requiredCapability, long offerSequence) => throw CreateNotConfiguredException();

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
}
