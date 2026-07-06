using System.Collections.Concurrent;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;
using Rift.Daemon.Core.Interfaces;

namespace Rift.Daemon.Core;

public sealed class ClipboardService : IClipboardService
{
    private const int DefaultOfferExpiryMs = 120000;
    private static readonly TimeSpan DefaultFetchResponseTimeout = TimeSpan.FromSeconds(15);
    private static readonly TimeSpan TrustedReconnectTimeout = TimeSpan.FromSeconds(3);
    private const string RequiredCapability = "clipboard.offer_fetch";

    private readonly ITransport _transport;
    private readonly ITrustStore _trustStore;
    private readonly IDiscoveryCoordinator _discoveryCoordinator;
    private readonly IPresenceService _presenceService;
    private readonly IIdentityManager _identityManager;
    private readonly ISecurityEventLog _securityEventLog;
    private readonly IIpcNotificationService? _ipcNotificationService;
    private readonly ILogger<ClipboardService> _logger;
    private readonly TimeSpan _fetchResponseTimeout;
    private readonly TimeProvider _timeProvider = TimeProvider.System;

    private readonly ConcurrentDictionary<string, ConcurrentDictionary<string, (byte[] Payload, DateTimeOffset ExpiresAt)>> _pendingStoreAndForward = new(StringComparer.Ordinal);
    private readonly ConcurrentDictionary<string, Task> _storeAndForwardTasks = new(StringComparer.Ordinal);

    private readonly ConcurrentDictionary<string, LocalClipboardOffer> _localOffers = new(StringComparer.Ordinal);
    private readonly ConcurrentDictionary<string, ClipboardOfferInfo> _remoteOffers = new(StringComparer.Ordinal);
    private readonly ConcurrentDictionary<string, long> _peerOfferHighWaterMarks = new(StringComparer.Ordinal);
    private readonly ConcurrentDictionary<string, PendingClipboardFetch> _pendingFetches = new(StringComparer.Ordinal);
    private readonly ConcurrentDictionary<string, Task> _pendingTrustedReconnects = new(StringComparer.Ordinal);
    private long _nextOfferSequence;

    public ClipboardService(
        ITransport transport,
        ITrustStore trustStore,
        IDiscoveryCoordinator discoveryCoordinator,
        IPresenceService presenceService,
        IIdentityManager identityManager,
        ISecurityEventLog securityEventLog,
        IIpcNotificationService? ipcNotificationService = null,
        ILogger<ClipboardService>? logger = null,
        TimeSpan? fetchResponseTimeout = null)
    {
        _transport = transport;
        _trustStore = trustStore;
        _discoveryCoordinator = discoveryCoordinator;
        _presenceService = presenceService;
        _identityManager = identityManager;
        _securityEventLog = securityEventLog;
        _ipcNotificationService = ipcNotificationService;
        _logger = logger ?? NullLogger<ClipboardService>.Instance;
        _fetchResponseTimeout = fetchResponseTimeout ?? DefaultFetchResponseTimeout;
    }

    public async Task<string[]> BroadcastOfferAsync(string offerId, string contentType, long size, string hash, long expiresInMs, string requiredCapability, long offerSequence)
    {
        var trustedPeers = _trustStore.GetAllPeers()
            .Where(peer => peer.State == TrustState.Trusted && PeerHasCapability(peer.DeviceId, requiredCapability))
            .Select(peer => peer.DeviceId)
            .ToArray();

        var successfulPeers = new List<string>();
        foreach (var deviceId in trustedPeers)
        {
            var envelope = new
            {
                rift = "0.1-draft",
                type = "clipboard.offer",
                messageId = Guid.NewGuid().ToString("D"),
                sourceDeviceId = _identityManager.GetDeviceId(),
                payload = new
                {
                    offerId,
                    contentType,
                    byteSize = size,
                    sha256 = hash,
                    expiresInMs,
                    sourceDeviceId = _identityManager.GetDeviceId(),
                    requiredCapability,
                    offerSequence
                }
            };

            try
            {

                var bytes = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(envelope));
                await SendProtectedMessageAsync(deviceId, bytes, CancellationToken.None);
                successfulPeers.Add(deviceId);
            }
            catch (Exception ex)
            {
                _logger.LogDebug(ex, "Failed to broadcast clipboard offer {OfferId} to {DeviceId}. Starting store-and-forward.", offerId, deviceId);
                ScheduleStoreAndForward(deviceId, offerId, envelope, expiresInMs);
            }
        }
        
        return successfulPeers.ToArray();
    }

    private void ScheduleStoreAndForward(string deviceId, string offerId, object envelope, long expiresInMs)
    {
        var expiresAt = _timeProvider.GetUtcNow().AddMilliseconds(expiresInMs);
        var bytes = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(envelope));
        var peerQueue = _pendingStoreAndForward.GetOrAdd(deviceId, _ => new ConcurrentDictionary<string, (byte[], DateTimeOffset)>(StringComparer.Ordinal));
        peerQueue[offerId] = (bytes, expiresAt);

        _storeAndForwardTasks.GetOrAdd(deviceId, id =>
        {
            return Task.Run(async () =>
            {
                try
                {
                    await StoreAndForwardLoopAsync(id);
                }
                finally
                {
                    _storeAndForwardTasks.TryRemove(id, out _);
                }
            });
        });
    }

    private async Task StoreAndForwardLoopAsync(string deviceId)
    {
        while (_pendingStoreAndForward.TryGetValue(deviceId, out var peerQueue) && !peerQueue.IsEmpty)
        {
            await Task.Delay(TimeSpan.FromSeconds(5));
            var now = _timeProvider.GetUtcNow();

            foreach (var kvp in peerQueue)
            {
                if (now >= kvp.Value.ExpiresAt)
                {
                    peerQueue.TryRemove(kvp.Key, out _);
                    _logger.LogWarning("Store-and-forward expired for offer {OfferId} to peer {DeviceId} before reachability was restored.", kvp.Key, deviceId);
                }
            }

            if (peerQueue.IsEmpty)
            {
                _pendingStoreAndForward.TryRemove(deviceId, out _);
                break;
            }

            try
            {
                foreach (var kvp in peerQueue)
                {
                    await SendProtectedMessageAsync(deviceId, kvp.Value.Payload, CancellationToken.None);
                    peerQueue.TryRemove(kvp.Key, out _);
                    _logger.LogInformation("Successfully late-delivered clipboard offer {OfferId} to {DeviceId} via store-and-forward.", kvp.Key, deviceId);
                }
            }
            catch (Exception ex)
            {
                _logger.LogDebug("Store-and-forward retry failed for {DeviceId}: {Message}", deviceId, ex.Message);
            }
        }
    }

    public async Task HandleOfferReceivedAsync(ReceivedClipboardOffer offer)
    {
        EnsurePayloadIdentityMatches(offer.DeviceId, offer.PayloadSourceDeviceId, "clipboard.offer");
        EnsurePeerCanUseClipboard(offer.DeviceId, offer.RequiredCapability);

        var accepted = true;
        _peerOfferHighWaterMarks.AddOrUpdate(
            offer.DeviceId,
            offer.OfferSequence,
            (_, currentHighWaterMark) =>
            {
                if (offer.OfferSequence <= currentHighWaterMark)
                {
                    accepted = false;
                    return currentHighWaterMark;
                }

                return offer.OfferSequence;
            });

        if (!accepted)
        {
            LogEvent(SecurityEventTypes.ClipboardOfferReplay, offer.DeviceId, SecurityEventSeverity.Warning, SecurityEventOutcome.Denied, null);
            return;
        }

        _remoteOffers[offer.OfferId] = new ClipboardOfferInfo
        {
            OfferId = offer.OfferId,
            SourceDeviceId = offer.DeviceId,
            ContentType = offer.ContentType,
            ByteSize = offer.ByteSize,
            Sha256 = offer.Sha256,
            ExpiresAt = DateTimeOffset.UtcNow.AddMilliseconds(offer.ExpiresInMs).ToString("O")
        };

        LogEvent(SecurityEventTypes.ClipboardOffered, offer.DeviceId, SecurityEventSeverity.Info, SecurityEventOutcome.Success, null);
        await NotifyClipboardOfferAsync(offer).ConfigureAwait(false);
    }

    public async Task<byte[]> FetchContentAsync(string deviceId, string offerId)
    {
        var result = await FetchClipboardContentAsync(offerId, CancellationToken.None);
        return Convert.FromBase64String(result.ContentBase64);
    }

    public async Task<NotifyClipboardChangeResult> NotifyClipboardChangeAsync(string contentType, long byteSize, string sha256, string contentBase64, CancellationToken cancellationToken)
    {
        if (!VerifyClipboardPayload(contentBase64, byteSize, sha256))
        {
            throw new ClipboardFailureException("HashMismatch", -32006, "Clipboard content did not match the declared size or SHA-256 hash.");
        }

        var offerId = Guid.NewGuid().ToString("D");
        var offerSequence = Interlocked.Increment(ref _nextOfferSequence);
        var now = DateTimeOffset.UtcNow;

        _localOffers[offerId] = new LocalClipboardOffer
        {
            OfferId = offerId,
            ContentType = contentType,
            ByteSize = byteSize,
            Sha256 = sha256,
            ContentBase64 = contentBase64,
            ExpiresAt = now.AddMilliseconds(DefaultOfferExpiryMs),
            OfferSequence = offerSequence
        };

        var recipients = await BroadcastOfferAsync(offerId, contentType, byteSize, sha256, DefaultOfferExpiryMs, RequiredCapability, offerSequence);

        LogEvent(SecurityEventTypes.ClipboardOffered, null, SecurityEventSeverity.Info, SecurityEventOutcome.Success, null);

        return new NotifyClipboardChangeResult
        {
            OfferId = offerId,
            ExpiresInMs = DefaultOfferExpiryMs,
            BroadcastTo = recipients
        };
    }

    public async Task<ListClipboardOffersResult> ListClipboardOffersAsync()
    {
        await PruneExpiredRemoteOffersAsync().ConfigureAwait(false);

        var now = DateTimeOffset.UtcNow;
        var remote = _remoteOffers.Values
            .Where(offer => DateTimeOffset.Parse(offer.ExpiresAt) > now);

        var local = _localOffers.Values
            .Where(offer => offer.ExpiresAt > now)
            .Select(offer => new ClipboardOfferInfo
            {
                OfferId = offer.OfferId,
                SourceDeviceId = _identityManager.GetDeviceId(),
                ContentType = offer.ContentType,
                ByteSize = offer.ByteSize,
                Sha256 = offer.Sha256,
                ExpiresAt = offer.ExpiresAt.ToString("O")
            });

        var offers = remote.Concat(local)
            .OrderBy(offer => offer.ExpiresAt, StringComparer.Ordinal)
            .ToArray();

        return new ListClipboardOffersResult
        {
            Offers = offers
        };
    }

    public async Task<FetchClipboardContentResult> FetchClipboardContentAsync(string offerId, CancellationToken cancellationToken)
    {
        if (!_remoteOffers.TryGetValue(offerId, out var offer))
        {
            throw new ClipboardFailureException("NotFound", -32009, $"Offer '{offerId}' was not found.");
        }

        if (DateTimeOffset.Parse(offer.ExpiresAt) <= DateTimeOffset.UtcNow)
        {
            _remoteOffers.TryRemove(offerId, out _);
            LogEvent(SecurityEventTypes.ClipboardExpired, offer.SourceDeviceId, SecurityEventSeverity.Warning, SecurityEventOutcome.Failure, "OfferExpired");
            throw new ClipboardFailureException("OfferExpired", -32002, $"Offer '{offerId}' has expired.");
        }

        await PruneExpiredRemoteOffersAsync().ConfigureAwait(false);

        EnsurePeerCanUseClipboard(offer.SourceDeviceId, RequiredCapability);

        var pendingFetch = new PendingClipboardFetch(
            offer.SourceDeviceId,
            new TaskCompletionSource<FetchClipboardContentResult>(TaskCreationOptions.RunContinuationsAsynchronously));
        if (!_pendingFetches.TryAdd(offerId, pendingFetch))
        {
            throw new ClipboardFailureException("PolicyDenied", -32010, $"A fetch for offer '{offerId}' is already in progress.");
        }

        try
        {
            using var timeoutCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            timeoutCts.CancelAfter(_fetchResponseTimeout);

            var envelope = new
            {
                rift = "0.1-draft",
                type = "clipboard.fetchRequest",
                messageId = Guid.NewGuid().ToString("D"),
                sourceDeviceId = _identityManager.GetDeviceId(),
                payload = new
                {
                    offerId,
                    requestingDeviceId = _identityManager.GetDeviceId()
                }
            };

            var bytes = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(envelope));
            try
            {
                await SendProtectedMessageAsync(offer.SourceDeviceId, bytes, timeoutCts.Token);
            }
            catch (InvalidOperationException ex) when (string.Equals(ex.Message, "PayloadTooLarge", StringComparison.Ordinal))
            {
                throw new ClipboardFailureException("PayloadTooLarge", -32007, "Clipboard request exceeded the transport frame limit.");
            }
            catch (InvalidOperationException ex)
            {
                throw new ClipboardFailureException("PeerUnreachable", -32000, ex.Message);
            }
            catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
            {
                LogEvent(SecurityEventTypes.ClipboardFetched, offer.SourceDeviceId, SecurityEventSeverity.Warning, SecurityEventOutcome.Failure, "Timeout");
                throw new ClipboardFailureException("Timeout", -32011, $"Clipboard fetch for offer '{offerId}' timed out.");
            }

            try
            {
                return await pendingFetch.CompletionSource.Task.WaitAsync(timeoutCts.Token);
            }
            catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
            {
                LogEvent(SecurityEventTypes.ClipboardFetched, offer.SourceDeviceId, SecurityEventSeverity.Warning, SecurityEventOutcome.Failure, "Timeout");
                throw new ClipboardFailureException("Timeout", -32011, $"Clipboard fetch for offer '{offerId}' timed out.");
            }
        }
        finally
        {
            _pendingFetches.TryRemove(offerId, out _);
        }
    }

    public async Task HandleFetchRequestAsync(string deviceId, string offerId, string requestingDeviceId, CancellationToken cancellationToken)
    {
        if (_pendingStoreAndForward.TryGetValue(deviceId, out var peerQueue))
        {
            if (peerQueue.TryRemove(offerId, out _))
            {
                _logger.LogDebug("Store-and-forward cancelled for offer {OfferId} to {DeviceId} because fetchRequest was received.", offerId, deviceId);
            }
        }

        try
        {
            EnsurePayloadIdentityMatches(deviceId, requestingDeviceId, "clipboard.fetchRequest");
            EnsurePeerCanUseClipboard(deviceId, RequiredCapability);
        }
        catch (ClipboardFailureException ex)
        {
            await SendFetchRejectAsync(deviceId, offerId, ex.FailureReason, ex.Message, cancellationToken);
            return;
        }

        if (!_localOffers.TryGetValue(offerId, out var offer) || offer.ExpiresAt <= DateTimeOffset.UtcNow)
        {
            _localOffers.TryRemove(offerId, out _);
            LogEvent(SecurityEventTypes.ClipboardExpired, deviceId, SecurityEventSeverity.Warning, SecurityEventOutcome.Failure, "OfferExpired");
            await SendFetchRejectAsync(deviceId, offerId, "OfferExpired", "offer expired", cancellationToken);
            return;
        }

        var envelope = new
        {
            rift = "0.1-draft",
            type = "clipboard.fetchResponse",
            messageId = Guid.NewGuid().ToString("D"),
            sourceDeviceId = _identityManager.GetDeviceId(),
            payload = new
            {
                offerId,
                contentBase64 = offer.ContentBase64,
                byteSize = offer.ByteSize,
                sha256 = offer.Sha256
            }
        };

        var bytes = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(envelope));
        await _transport.SendAsync(deviceId, bytes, cancellationToken);
        LogEvent(SecurityEventTypes.ClipboardFetched, deviceId, SecurityEventSeverity.Info, SecurityEventOutcome.Success, null);
    }

    public Task HandleFetchResponseAsync(string deviceId, string offerId, string contentBase64, long byteSize, string sha256, CancellationToken cancellationToken)
    {
        if (_pendingFetches.TryGetValue(offerId, out var pendingFetch) &&
            !string.Equals(pendingFetch.ExpectedSourceDeviceId, deviceId, StringComparison.Ordinal))
        {
            LogEvent(SecurityEventTypes.AuthFailed, deviceId, SecurityEventSeverity.Critical, SecurityEventOutcome.Denied, "Unauthorized");
            return Task.CompletedTask;
        }

        if (pendingFetch is not null)
        {
            var verified = VerifyClipboardPayload(contentBase64, byteSize, sha256);
            if (!verified)
            {
                LogEvent(SecurityEventTypes.ClipboardFetched, deviceId, SecurityEventSeverity.Warning, SecurityEventOutcome.Failure, "HashMismatch");
                pendingFetch.CompletionSource.TrySetException(new ClipboardFailureException("HashMismatch", -32006, "Clipboard content failed size or SHA-256 verification."));
                return Task.CompletedTask;
            }

            pendingFetch.CompletionSource.TrySetResult(new FetchClipboardContentResult
            {
                OfferId = offerId,
                ContentBase64 = contentBase64,
                ByteSize = byteSize,
                Sha256 = sha256,
                Verified = verified
            });
        }

        return Task.CompletedTask;
    }

    public Task HandleFetchRejectAsync(string deviceId, string offerId, string failureReason, string? message, CancellationToken cancellationToken)
    {
        if (_pendingFetches.TryGetValue(offerId, out var pendingFetch) &&
            !string.Equals(pendingFetch.ExpectedSourceDeviceId, deviceId, StringComparison.Ordinal))
        {
            LogEvent(SecurityEventTypes.AuthFailed, deviceId, SecurityEventSeverity.Critical, SecurityEventOutcome.Denied, "Unauthorized");
            return Task.CompletedTask;
        }

        if (pendingFetch is not null)
        {
            pendingFetch.CompletionSource.TrySetException(CreateFailureException(failureReason, message));
        }

        return Task.CompletedTask;
    }

    private async Task SendFetchRejectAsync(string deviceId, string offerId, string failureReason, string message, CancellationToken cancellationToken)
    {
        var envelope = new
        {
            rift = "0.1-draft",
            type = "clipboard.fetchReject",
            messageId = Guid.NewGuid().ToString("D"),
            sourceDeviceId = _identityManager.GetDeviceId(),
            payload = new
            {
                offerId,
                failureReason,
                message
            }
        };

        var bytes = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(envelope));
        await _transport.SendAsync(deviceId, bytes, cancellationToken);
    }

    private static bool VerifyClipboardPayload(string contentBase64, long byteSize, string sha256)
    {
        byte[] contentBytes;
        try
        {
            contentBytes = Convert.FromBase64String(contentBase64);
        }
        catch (FormatException)
        {
            return false;
        }

        if (contentBytes.LongLength != byteSize)
        {
            return false;
        }

        var computedHash = Convert.ToHexStringLower(SHA256.HashData(contentBytes));
        return string.Equals(computedHash, sha256, StringComparison.OrdinalIgnoreCase);
    }

    private void EnsurePeerCanUseClipboard(string deviceId, string requiredCapability)
    {
        var peer = _trustStore.GetPeer(deviceId);
        if (peer is null || peer.State != TrustState.Trusted)
        {
            throw new ClipboardFailureException("Unauthorized", -32004, "Peer is not trusted.");
        }

        if (!PeerHasCapability(deviceId, requiredCapability))
        {
            throw new ClipboardFailureException("CapabilityUnavailable", -32003, $"Capability '{requiredCapability}' is not negotiated for peer '{deviceId}'.");
        }
    }

    private bool PeerHasCapability(string deviceId, string requiredCapability)
    {
        var presence = _presenceService.GetPeerPresence(deviceId);
        return presence is not null && presence.Capabilities.Contains(requiredCapability, StringComparer.Ordinal);
    }

    private void EnsurePayloadIdentityMatches(string authenticatedDeviceId, string payloadDeviceId, string messageType)
    {
        if (string.Equals(authenticatedDeviceId, payloadDeviceId, StringComparison.Ordinal))
        {
            return;
        }

        LogEvent(SecurityEventTypes.AuthFailed, authenticatedDeviceId, SecurityEventSeverity.Critical, SecurityEventOutcome.Denied, "Unauthorized");
        throw new ClipboardFailureException("Unauthorized", -32004, $"{messageType} payload identity did not match the authenticated peer identity.");
    }

    private async Task PruneExpiredRemoteOffersAsync()
    {
        var now = DateTimeOffset.UtcNow;
        List<Task>? notificationTasks = null;
        foreach (var entry in _remoteOffers)
        {
            if (DateTimeOffset.Parse(entry.Value.ExpiresAt) > now)
            {
                continue;
            }

            if (_remoteOffers.TryRemove(entry.Key, out var removed))
            {
                LogEvent(SecurityEventTypes.ClipboardExpired, removed.SourceDeviceId, SecurityEventSeverity.Warning, SecurityEventOutcome.Failure, "OfferExpired");
                notificationTasks ??= [];
                notificationTasks.Add(NotifyClipboardExpiredAsync(removed.OfferId));
            }
        }

        if (notificationTasks is not null)
        {
            await Task.WhenAll(notificationTasks).ConfigureAwait(false);
        }
    }

    private async Task NotifyClipboardOfferAsync(ReceivedClipboardOffer offer)
    {
        if (_ipcNotificationService is null)
        {
            return;
        }

        try
        {
            await _ipcNotificationService.NotifyAsync(
                "rift.onClipboardOffer",
                new
                {
                    offerId = offer.OfferId,
                    sourceDeviceId = offer.DeviceId,
                    contentType = offer.ContentType,
                    byteSize = offer.ByteSize,
                    sha256 = offer.Sha256,
                    expiresInMs = offer.ExpiresInMs
                }).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Failed to notify IPC clients about clipboard offer {OfferId}.", offer.OfferId);
        }
    }

    private async Task NotifyClipboardExpiredAsync(string offerId)
    {
        if (_ipcNotificationService is null)
        {
            return;
        }

        try
        {
            await _ipcNotificationService.NotifyAsync(
                "rift.onClipboardExpired",
                new
                {
                    offerId
                }).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Failed to notify IPC clients that clipboard offer {OfferId} expired.", offerId);
        }
    }

    private static ClipboardFailureException CreateFailureException(string failureReason, string? message)
    {
        return failureReason switch
        {
            "OfferExpired" => new ClipboardFailureException(failureReason, -32002, message ?? "Clipboard offer expired."),
            "CapabilityUnavailable" => new ClipboardFailureException(failureReason, -32003, message ?? "Clipboard capability is unavailable."),
            "Unauthorized" => new ClipboardFailureException(failureReason, -32004, message ?? "Peer is not authorized for clipboard access."),
            "HashMismatch" => new ClipboardFailureException(failureReason, -32006, message ?? "Clipboard content failed hash verification."),
            "PayloadTooLarge" => new ClipboardFailureException(failureReason, -32007, message ?? "Clipboard payload exceeded the transport frame limit."),
            "Timeout" => new ClipboardFailureException(failureReason, -32011, message ?? "Clipboard request timed out."),
            _ => new ClipboardFailureException(failureReason, -32001, message ?? failureReason)
        };
    }

    private async Task EnsureConnectedForTrustedPeerAsync(string peerDeviceId, CancellationToken cancellationToken)
    {
        if (_transport.HasActiveSession(peerDeviceId))
        {
            return;
        }

        var peer = _trustStore.GetPeer(peerDeviceId);
        if (peer is null || peer.State != TrustState.Trusted)
        {
            throw new ClipboardFailureException("Unauthorized", -32004, $"Peer '{peerDeviceId}' is not trusted.");
        }

        if (peer.TrustedEndpoints.Count == 0)
        {
            try
            {
                await ReconnectTrustedPeerViaDiscoveryAsync(peerDeviceId, cancellationToken).ConfigureAwait(false);
            }
            catch (ClipboardFailureException ex) when (ex.FailureReason == "PeerUnreachable")
            {
                _logger.LogDebug(
                    ex,
                    "Trusted peer {DeviceId} had no persisted/discoverable endpoint for clipboard reconnect.",
                    peerDeviceId);
            }
            return;
        }

        var reconnectTask = _pendingTrustedReconnects.GetOrAdd(
            peerDeviceId,
            _ => ReconnectTrustedPeerCoreAsync(peerDeviceId, peer, cancellationToken));

        try
        {
            await reconnectTask.ConfigureAwait(false);
        }
        catch (ClipboardFailureException ex) when (ex.FailureReason == "PeerUnreachable")
        {
            _logger.LogDebug(
                ex,
                "Trusted reconnect for peer {DeviceId} could not find a reachable endpoint before clipboard send.",
                peerDeviceId);
        }
        finally
        {
            if (reconnectTask.IsCompleted)
            {
                _pendingTrustedReconnects.TryRemove(peerDeviceId, out _);
            }
        }
    }

    private async Task SendProtectedMessageAsync(string peerDeviceId, ReadOnlyMemory<byte> frameBody, CancellationToken cancellationToken)
    {
        try
        {
            await _transport.SendAsync(peerDeviceId, frameBody, cancellationToken).ConfigureAwait(false);
            return;
        }
        catch (InvalidOperationException ex) when (IsNoOpenSessionError(ex))
        {
            _logger.LogDebug(
                ex,
                "No active protected session was available for peer {DeviceId}. Attempting trusted reconnect before retrying clipboard message.",
                peerDeviceId);
        }

        await EnsureConnectedForTrustedPeerAsync(peerDeviceId, cancellationToken).ConfigureAwait(false);
        await _transport.SendAsync(peerDeviceId, frameBody, cancellationToken).ConfigureAwait(false);
    }

    private static bool IsNoOpenSessionError(InvalidOperationException ex)
    {
        return ex.Message.Contains("No open session exists", StringComparison.Ordinal);
    }

    private async Task ReconnectTrustedPeerCoreAsync(string peerDeviceId, PeerIdentity peer, CancellationToken cancellationToken)
    {
        Exception? lastError = null;
        foreach (var endpoint in peer.TrustedEndpoints)
        {
            try
            {
                using var timeoutCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
                timeoutCts.CancelAfter(TrustedReconnectTimeout);
                await _transport.ConnectToPeerAsync(endpoint.Address, endpoint.Port, timeoutCts.Token).ConfigureAwait(false);
                _logger.LogInformation(
                    "Reconnected trusted peer {DeviceId} using persisted endpoint {Address}:{Port} from {Source}.",
                    peerDeviceId,
                    endpoint.Address,
                    endpoint.Port,
                    endpoint.Source);
                return;
            }
            catch (Exception ex) when (ex is not OperationCanceledException || !cancellationToken.IsCancellationRequested)
            {
                lastError = ex;
                _logger.LogWarning(
                    ex,
                    "Trusted reconnect attempt failed for peer {DeviceId} via {Address}:{Port} from {Source}.",
                    peerDeviceId,
                    endpoint.Address,
                    endpoint.Port,
                    endpoint.Source);
            }
        }

        if (_discoveryCoordinator.TryGetDiscoveredPeer(peerDeviceId, out var discoveredPeer) &&
            discoveredPeer is not null)
        {
            _logger.LogInformation(
                "Falling back to discovery reconnect for trusted peer {DeviceId} after persisted endpoints failed.",
                peerDeviceId);
            await ReconnectTrustedPeerViaDiscoveryAsync(peerDeviceId, cancellationToken).ConfigureAwait(false);
            return;
        }

        throw new ClipboardFailureException(
            "PeerUnreachable",
            -32000,
            $"Failed to reconnect trusted peer '{peerDeviceId}' using persisted endpoints. {lastError?.Message ?? "No endpoint succeeded."}");
    }

    private async Task ReconnectTrustedPeerViaDiscoveryAsync(string peerDeviceId, CancellationToken cancellationToken)
    {
        if (!_discoveryCoordinator.TryGetDiscoveredPeer(peerDeviceId, out var peer) ||
            peer is null)
        {
            throw new ClipboardFailureException(
                "PeerUnreachable",
                -32000,
                $"Trusted peer '{peerDeviceId}' is not currently discoverable.");
        }

        var endpoints = peer.ObservedEndpoints.Count > 0
            ? peer.ObservedEndpoints
            : [new DiscoveredPeerEndpoint { Address = peer.Address, Port = peer.Port }];
        Exception? lastError = null;

        foreach (var endpoint in endpoints)
        {
            try
            {
                using var timeoutCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
                timeoutCts.CancelAfter(TrustedReconnectTimeout);
                await _transport.ConnectToPeerAsync(endpoint.Address, endpoint.Port, timeoutCts.Token).ConfigureAwait(false);
                _logger.LogInformation(
                    "Reconnected trusted peer {DeviceId} using discovery endpoint {Address}:{Port}.",
                    peerDeviceId,
                    endpoint.Address,
                    endpoint.Port);
                return;
            }
            catch (Exception ex) when (ex is not OperationCanceledException || !cancellationToken.IsCancellationRequested)
            {
                lastError = ex;
                _logger.LogWarning(
                    ex,
                    "Discovery reconnect attempt failed for trusted peer {DeviceId} via {Address}:{Port}.",
                    peerDeviceId,
                    endpoint.Address,
                    endpoint.Port);
            }
        }

        throw new ClipboardFailureException(
            "PeerUnreachable",
            -32000,
            $"Failed to reconnect trusted peer '{peerDeviceId}' using discovery endpoints. {lastError?.Message ?? "No endpoint succeeded."}");
    }

    private void LogEvent(string eventType, string? peerDeviceId, SecurityEventSeverity severity, SecurityEventOutcome outcome, string? failureReason)
    {
        _ = _securityEventLog.LogEventAsync(new SecurityEventRecord
        {
            EventType = eventType,
            Severity = severity,
            LocalDeviceId = _identityManager.GetDeviceId(),
            PeerDeviceId = peerDeviceId,
            Outcome = outcome,
            FailureReason = failureReason
        }).ContinueWith(
            task =>
            {
                if (task.IsFaulted)
                {
                    _logger.LogError(task.Exception, "Failed to persist clipboard security event {EventType}.", eventType);
                }
            },
            CancellationToken.None,
            TaskContinuationOptions.ExecuteSynchronously,
            TaskScheduler.Default);
    }

    private sealed class LocalClipboardOffer
    {
        public string OfferId { get; init; } = string.Empty;
        public string ContentType { get; init; } = string.Empty;
        public long ByteSize { get; init; }
        public string Sha256 { get; init; } = string.Empty;
        public string ContentBase64 { get; init; } = string.Empty;
        public DateTimeOffset ExpiresAt { get; init; }
        public long OfferSequence { get; init; }
    }

    private sealed record PendingClipboardFetch(
        string ExpectedSourceDeviceId,
        TaskCompletionSource<FetchClipboardContentResult> CompletionSource);
}
