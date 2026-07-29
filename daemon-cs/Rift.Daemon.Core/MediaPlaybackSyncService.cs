using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;
using Rift.Daemon.Core.Interfaces;

namespace Rift.Daemon.Core;

public sealed class MediaPlaybackSyncService : IMediaPlaybackSyncService
{
    private const string RequiredCapability = "media.playback";
    private static readonly StringComparer Comparer = StringComparer.Ordinal;
    private static readonly TimeSpan DefaultActionTimeout = TimeSpan.FromSeconds(30);
    private static readonly Regex Rfc3339UtcTimestamp = new(
        @"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|\+00:00)$",
        RegexOptions.CultureInvariant);
    private static readonly HashSet<string> FailureReasons = new(Comparer)
    {
        "PeerUnreachable",
        "PeerRejected",
        "OfferExpired",
        "CapabilityUnavailable",
        "ConnectionLost",
        "Timeout",
        "PolicyDenied",
        "AuthenticationFailed",
        "Unauthorized",
        "HashMismatch",
        "MalformedMessage",
        "VersionMismatch",
        "ProtocolError",
        "PayloadTooLarge",
        "InvalidTransition"
    };
    private readonly Lock _gate = new();
    private readonly ITransport _transport;
    private readonly IPresenceService _presenceService;
    private readonly IIdentityManager _identityManager;
    private readonly IOperationService _operationService;
    private readonly ISecurityEventLog _securityEventLog;
    private readonly IIpcNotificationService? _ipcNotificationService;
    private readonly ILocalMediaPlaybackActionHandler? _localActionHandler;
    private readonly ILogger<MediaPlaybackSyncService> _logger;
    private readonly TimeSpan _actionTimeout;
    private readonly Dictionary<string, MediaPlaybackRecord> _playbacks = new(Comparer);
    private readonly Dictionary<string, PendingPlaybackAction> _pendingActionsByOperationId = new(Comparer);
    private readonly Dictionary<string, string> _pendingActionKeys = new(Comparer);
    private readonly Dictionary<string, PendingIncomingMediaPlaybackAction> _pendingIncomingActionsByRequestId = new(Comparer);
    private readonly Dictionary<string, Timer> _pendingIncomingActionTimers = new(Comparer);

    public MediaPlaybackSyncService(
        ITransport transport,
        IPresenceService presenceService,
        IIdentityManager identityManager,
        IOperationService operationService,
        ISecurityEventLog securityEventLog,
        IIpcNotificationService? ipcNotificationService = null,
        ILocalMediaPlaybackActionHandler? localActionHandler = null,
        ILogger<MediaPlaybackSyncService>? logger = null,
        TimeSpan? actionTimeout = null)
    {
        _transport = transport;
        _presenceService = presenceService;
        _identityManager = identityManager;
        _operationService = operationService;
        _securityEventLog = securityEventLog;
        _ipcNotificationService = ipcNotificationService;
        _localActionHandler = localActionHandler;
        _logger = logger ?? NullLogger<MediaPlaybackSyncService>.Instance;
        _actionTimeout = actionTimeout ?? DefaultActionTimeout;
    }

    public async Task PublishLocalPlaybackToPeerAsync(
        string peerDeviceId,
        MediaPlaybackRecord playback,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var normalized = NormalizeLocalRecord(playback);
        ValidateRecord(normalized);
        if (!_transport.HasProtectedSession(peerDeviceId))
        {
            throw new MediaPlaybackSyncFailureException($"Peer '{peerDeviceId}' does not have a protected session.", -32003);
        }

        var bytes = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(CreateEnvelope(
            "media.playbackPosted",
            CreatePlaybackPayload(normalized))));
        await _transport.SendAsync(peerDeviceId, bytes, cancellationToken).ConfigureAwait(false);
    }

    public async Task SendPeerErrorAsync(
        string peerDeviceId,
        string failureReason,
        string? refMessageId,
        string message,
        CancellationToken cancellationToken)
    {
        var bytes = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(CreateEnvelope(
            "error",
            new
            {
                failureReason,
                refMessageId,
                message
            })));
        await _transport.SendAsync(peerDeviceId, bytes, cancellationToken).ConfigureAwait(false);
    }

    public Task<ListMediaPlaybackResult> ListMediaPlaybackAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        lock (_gate)
        {
            return Task.FromResult(new ListMediaPlaybackResult
            {
                Playbacks = _playbacks.Values
                    .Where(playback => !playback.IsRemoved)
                    .Select(CloneRecord)
                    .ToArray()
            });
        }
    }

    public Task<MediaPlaybackRecord> GetMediaPlaybackAsync(
        string sourceDeviceId,
        string playbackId,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (string.IsNullOrWhiteSpace(sourceDeviceId) || string.IsNullOrWhiteSpace(playbackId))
        {
            throw new MediaPlaybackSyncFailureException("A source device ID and playback ID are required.", -32009);
        }

        lock (_gate)
        {
            var record = _playbacks.GetValueOrDefault(GetPlaybackKey(sourceDeviceId, playbackId));
            if (record?.IsRemoved == true)
            {
                record = null;
            }
            if (record is null)
            {
                throw new MediaPlaybackSyncFailureException($"Mirrored playback '{playbackId}' was not found.", -32009);
            }

            return Task.FromResult(CloneRecord(record));
        }
    }

    public async Task<NotifyLocalMediaPlaybackEventResult> HandleLocalPlaybackEventAsync(
        string eventType,
        MediaPlaybackRecord playback,
        string? removedAt,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (string.IsNullOrWhiteSpace(eventType))
        {
            throw new MediaPlaybackSyncFailureException("A media playback eventType is required.", -32602);
        }

        if (string.Equals(eventType, "removed", StringComparison.Ordinal))
        {
            ValidateOptionalAuditTimestamp(removedAt, "removedAt");
            var removed = new MediaPlaybackRemovedRecord
            {
                PlaybackId = playback.PlaybackId,
                SourceDeviceId = string.IsNullOrWhiteSpace(playback.SourceDeviceId) ? _identityManager.GetDeviceId() : playback.SourceDeviceId,
                RemovedAt = removedAt
            };
            await HandleMediaPlaybackRemovedAsync(removed, cancellationToken).ConfigureAwait(false);
            var broadcast = await BroadcastAsync("media.playbackRemoved", new
            {
                playbackId = removed.PlaybackId,
                sourceDeviceId = removed.SourceDeviceId,
                removedAt = removed.RemovedAt
            }, cancellationToken).ConfigureAwait(false);
            return new NotifyLocalMediaPlaybackEventResult
            {
                PlaybackId = removed.PlaybackId,
                BroadcastTo = broadcast
            };
        }

        var normalized = NormalizeLocalRecord(playback);
        ValidateRecord(normalized);

        if (string.Equals(eventType, "posted", StringComparison.Ordinal))
        {
            await HandleMediaPlaybackPostedAsync(normalized, cancellationToken).ConfigureAwait(false);
        }
        else if (string.Equals(eventType, "updated", StringComparison.Ordinal))
        {
            await HandleMediaPlaybackUpdatedAsync(normalized, cancellationToken).ConfigureAwait(false);
        }
        else
        {
            throw new MediaPlaybackSyncFailureException("Media playback eventType must be posted, updated, or removed.", -32602);
        }

        return new NotifyLocalMediaPlaybackEventResult
        {
            PlaybackId = normalized.PlaybackId,
            BroadcastTo = await BroadcastAsync(
                string.Equals(eventType, "posted", StringComparison.Ordinal) ? "media.playbackPosted" : "media.playbackUpdated",
                CreatePlaybackPayload(normalized),
                cancellationToken).ConfigureAwait(false)
        };
    }

    public async Task<PerformMediaPlaybackActionResult> PerformMediaPlaybackActionAsync(
        string sourceDeviceId,
        string playbackId,
        string action,
        long? positionMs,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (string.IsNullOrWhiteSpace(sourceDeviceId) || string.IsNullOrWhiteSpace(playbackId))
        {
            throw new MediaPlaybackSyncFailureException("A source device ID and playback ID are required.", -32009);
        }

        var normalizedAction = NormalizeAction(action, positionMs);
        MediaPlaybackRecord playback;
        lock (_gate)
        {
            playback = _playbacks.GetValueOrDefault(GetPlaybackKey(sourceDeviceId, playbackId))!;
            if (playback is null || playback.IsRemoved)
            {
                throw new MediaPlaybackSyncFailureException($"Mirrored playback '{playbackId}' was not found for '{sourceDeviceId}'.", -32009);
            }
        }

        EnsureActionAllowed(playback, normalizedAction);
        EnsurePeerCapability(playback.SourceDeviceId);

        var operationId = Guid.NewGuid().ToString("D");
        var actionKey = GetPendingActionKey(playback.SourceDeviceId, playback.PlaybackId, normalizedAction);
        lock (_gate)
        {
            if (_pendingActionKeys.ContainsKey(actionKey))
            {
                throw new MediaPlaybackSyncFailureException("A matching playback action is pending.", -32010);
            }
            _pendingActionKeys[actionKey] = operationId;
        }

        try
        {
            _operationService.CreateOperation(operationId, ToOperationType(normalizedAction), _identityManager.GetDeviceId(), playback.SourceDeviceId);
            _operationService.TransitionOperation(operationId, OperationState.Pending, details: CreateOperationDetails(playback, normalizedAction, positionMs));
            var pending = new PendingPlaybackAction(operationId, playback.PlaybackId, playback.SourceDeviceId, normalizedAction);
            lock (_gate)
            {
                _pendingActionsByOperationId[operationId] = pending;
            }
            _operationService.TransitionOperation(operationId, OperationState.Dispatched);
            pending.ExpiryTimer = new Timer(_ => ExpirePendingAction(operationId), null, _actionTimeout, Timeout.InfiniteTimeSpan);
        }
        catch
        {
            RemovePendingAction(operationId, playback.SourceDeviceId, playback.PlaybackId, normalizedAction)?.ExpiryTimer?.Dispose();
            throw;
        }

        try
        {
            var bytes = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(CreateEnvelope(
                "media.playbackActionRequest",
                new
                {
                    playbackId = playback.PlaybackId,
                    sourceDeviceId = playback.SourceDeviceId,
                    requestingDeviceId = _identityManager.GetDeviceId(),
                    action = normalizedAction,
                    positionMs,
                    requestedAt = DateTimeOffset.UtcNow.ToString("O")
                })));
            await _transport.SendAsync(playback.SourceDeviceId, bytes, cancellationToken).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            var pending = RemovePendingAction(operationId, playback.SourceDeviceId, playback.PlaybackId, normalizedAction);
            pending?.ExpiryTimer?.Dispose();
            if (pending is not null)
            {
                _operationService.TransitionOperation(operationId, OperationState.Failed, "PeerUnreachable");
            }
            throw new MediaPlaybackSyncFailureException($"Failed to send media playback action request: {ex.Message}", -32003);
        }

        return new PerformMediaPlaybackActionResult
        {
            OperationId = operationId,
            PlaybackId = playback.PlaybackId,
            Action = normalizedAction,
            State = "Pending"
        };
    }

    public async Task HandleMediaPlaybackPostedAsync(MediaPlaybackRecord playback, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        ValidateRecord(playback);
        lock (_gate)
        {
            _playbacks[GetPlaybackKey(playback.SourceDeviceId, playback.PlaybackId)] = CloneRecord(playback);
        }

        await NotifyIpcAsync("rift.onMediaPlaybackPosted", playback).ConfigureAwait(false);
        await LogEventAsync(SecurityEventTypes.MediaPlaybackSynced, playback.SourceDeviceId, SecurityEventOutcome.Success, null, new Dictionary<string, object?>
        {
            ["playbackId"] = playback.PlaybackId,
            ["appId"] = playback.AppId
        }).ConfigureAwait(false);
    }

    public async Task HandleMediaPlaybackUpdatedAsync(MediaPlaybackRecord playback, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        ValidateRecord(playback);
        lock (_gate)
        {
            _playbacks[GetPlaybackKey(playback.SourceDeviceId, playback.PlaybackId)] = CloneRecord(playback);
        }

        await NotifyIpcAsync("rift.onMediaPlaybackUpdated", playback).ConfigureAwait(false);
        await LogEventAsync(SecurityEventTypes.MediaPlaybackSynced, playback.SourceDeviceId, SecurityEventOutcome.Success, null, new Dictionary<string, object?>
        {
            ["playbackId"] = playback.PlaybackId,
            ["appId"] = playback.AppId,
            ["updated"] = true
        }).ConfigureAwait(false);
    }

    public async Task HandleMediaPlaybackRemovedAsync(MediaPlaybackRemovedRecord playback, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        ValidateOptionalAuditTimestamp(playback.RemovedAt, "removedAt");
        if (string.IsNullOrWhiteSpace(playback.PlaybackId) || string.IsNullOrWhiteSpace(playback.SourceDeviceId))
        {
            throw new InvalidOperationException("Media playback removal requires both sourceDeviceId and playbackId.");
        }

        MediaPlaybackRecord updated;
        lock (_gate)
        {
            var key = GetPlaybackKey(playback.SourceDeviceId, playback.PlaybackId);
            if (_playbacks.TryGetValue(key, out var existing))
            {
                updated = new MediaPlaybackRecord
                {
                    PlaybackId = existing.PlaybackId,
                    SourceDeviceId = existing.SourceDeviceId,
                    SourcePlatform = existing.SourcePlatform,
                    AppId = existing.AppId,
                    AppName = existing.AppName,
                    Title = existing.Title,
                    Artist = existing.Artist,
                    Album = existing.Album,
                    Artwork = existing.Artwork is null ? null : new Dictionary<string, object?>(existing.Artwork),
                    PlaybackState = existing.PlaybackState,
                    PositionMs = existing.PositionMs,
                    DurationMs = existing.DurationMs,
                    CanPlay = existing.CanPlay,
                    CanPause = existing.CanPause,
                    CanSkipNext = existing.CanSkipNext,
                    CanSkipPrevious = existing.CanSkipPrevious,
                    CanSeek = existing.CanSeek,
                    UpdatedAt = existing.UpdatedAt,
                    IsRemoved = true,
                    RemovedAt = playback.RemovedAt ?? DateTimeOffset.UtcNow.ToString("O")
                };
            }
            else
            {
                updated = new MediaPlaybackRecord
                {
                    PlaybackId = playback.PlaybackId,
                    SourceDeviceId = playback.SourceDeviceId,
                    AppId = "unknown",
                    AppName = "Unknown",
                    PlaybackState = "stopped",
                    UpdatedAt = playback.RemovedAt ?? DateTimeOffset.UtcNow.ToString("O"),
                    IsRemoved = true,
                    RemovedAt = playback.RemovedAt ?? DateTimeOffset.UtcNow.ToString("O")
                };
            }

            _playbacks[key] = updated;
        }

        await NotifyIpcAsync("rift.onMediaPlaybackRemoved", new
        {
            playbackId = updated.PlaybackId,
            sourceDeviceId = updated.SourceDeviceId,
            removedAt = updated.RemovedAt
        }).ConfigureAwait(false);
        await LogEventAsync(SecurityEventTypes.MediaPlaybackRemoved, updated.SourceDeviceId, SecurityEventOutcome.Success, null, new Dictionary<string, object?>
        {
            ["playbackId"] = updated.PlaybackId
        }).ConfigureAwait(false);
    }

    public async Task HandleMediaPlaybackActionResultAsync(MediaPlaybackActionResultRecord result, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (!string.Equals(result.RequestingDeviceId, _identityManager.GetDeviceId(), StringComparison.Ordinal))
        {
            throw new UnauthorizedAccessException("media.playbackActionResult requestingDeviceId did not match the local device identity.");
        }

        var action = NormalizeAction(result.Action, null, allowSeekWithoutPosition: true);
        var failureReason = NormalizeFailureReason(
            result.Success,
            result.FailureReason,
            invalidErrorCode: -32010);
        PendingPlaybackAction pending;
        lock (_gate)
        {
            var key = GetPendingActionKey(result.SourceDeviceId, result.PlaybackId, action);
            if (!_pendingActionKeys.TryGetValue(key, out var operationId) || !_pendingActionsByOperationId.TryGetValue(operationId, out pending!))
            {
                throw new InvalidOperationException($"No pending media playback action exists for '{result.PlaybackId}' ({action}).");
            }

            _pendingActionKeys.Remove(key);
            _pendingActionsByOperationId.Remove(operationId);
        }
        pending.ExpiryTimer?.Dispose();

        TryTransitionActive(pending.OperationId);
        if (result.Success)
        {
            _operationService.TransitionOperation(pending.OperationId, OperationState.Done);
        }
        else
        {
            _operationService.TransitionOperation(
                pending.OperationId,
                OperationState.Failed,
                failureReason,
                string.IsNullOrWhiteSpace(result.Message) ? null : new Dictionary<string, object?> { ["message"] = result.Message });
        }

        await NotifyIpcAsync("rift.onMediaPlaybackActionResult", new
        {
            playbackId = result.PlaybackId,
            sourceDeviceId = result.SourceDeviceId,
            action,
            operationId = pending.OperationId,
            state = result.Success ? "Done" : "Failed",
            success = result.Success,
            failureReason,
            message = result.Message
        }).ConfigureAwait(false);
        await LogEventAsync(SecurityEventTypes.MediaPlaybackActioned, result.SourceDeviceId, result.Success ? SecurityEventOutcome.Success : SecurityEventOutcome.Failure, failureReason, new Dictionary<string, object?>
        {
            ["playbackId"] = result.PlaybackId,
            ["action"] = action,
            ["operationId"] = pending.OperationId
        }).ConfigureAwait(false);
    }

    public async Task HandleMediaPlaybackActionRequestAsync(MediaPlaybackActionRequestRecord request, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (string.IsNullOrWhiteSpace(request.PlaybackId) ||
            string.IsNullOrWhiteSpace(request.SourceDeviceId) ||
            string.IsNullOrWhiteSpace(request.RequestingDeviceId))
        {
            throw new InvalidOperationException("media.playbackActionRequest requires playbackId, sourceDeviceId, and requestingDeviceId.");
        }
        if (!string.Equals(request.SourceDeviceId, _identityManager.GetDeviceId(), StringComparison.Ordinal))
        {
            throw new UnauthorizedAccessException("media.playbackActionRequest sourceDeviceId did not match the local device identity.");
        }

        var action = NormalizeAction(request.Action, request.PositionMs);
        ValidateOptionalAuditTimestamp(request.RequestedAt, "requestedAt");
        var requestId = Guid.NewGuid().ToString("D");
        var pending = new PendingIncomingMediaPlaybackAction
        {
            RequestId = requestId,
            PlaybackId = request.PlaybackId,
            SourceDeviceId = request.SourceDeviceId,
            RequestingDeviceId = request.RequestingDeviceId,
            Action = action,
            PositionMs = request.PositionMs
        };

        MediaPlaybackRecord? localPlayback;
        lock (_gate)
        {
            _playbacks.TryGetValue(GetPlaybackKey(request.SourceDeviceId, request.PlaybackId), out localPlayback);
        }
        if (localPlayback is null || localPlayback.IsRemoved || !IsActionAllowed(localPlayback, action))
        {
            await SendIncomingActionResultAsync(
                pending,
                success: false,
                failureReason: "CapabilityUnavailable",
                message: localPlayback is null || localPlayback.IsRemoved
                    ? "The local media playback was not found."
                    : $"The local media playback does not allow action '{action}'.",
                cancellationToken).ConfigureAwait(false);
            return;
        }

        lock (_gate)
        {
            _pendingIncomingActionsByRequestId[requestId] = pending;
            _pendingIncomingActionTimers[requestId] = new Timer(
                _ => _ = ExpireIncomingActionAsync(requestId),
                null,
                _actionTimeout,
                Timeout.InfiniteTimeSpan);
        }

        if (_localActionHandler is not null)
        {
            LocalMediaPlaybackActionResult result;
            try
            {
                result = await _localActionHandler.HandleActionAsync(pending, cancellationToken).ConfigureAwait(false);
            }
            catch (Exception ex)
            {
                _logger.LogWarning(ex, "Local media playback action handler failed for {Action} on {PlaybackId}.", action, request.PlaybackId);
                result = new LocalMediaPlaybackActionResult
                {
                    Success = false,
                    FailureReason = "CapabilityUnavailable",
                    Message = ex.Message
                };
            }

            var failureReason = NormalizeFailureReason(
                result.Success,
                result.FailureReason,
                invalidErrorCode: null);
            try
            {
                await ReportHandledMediaPlaybackActionAsync(
                    requestId,
                    result.Success,
                    failureReason,
                    result.Message,
                    cancellationToken).ConfigureAwait(false);
            }
            catch (MediaPlaybackSyncFailureException ex) when (ex.ErrorCode == -32009)
            {
                // The monotonic timeout already completed this request.
            }
            return;
        }

        if (_ipcNotificationService is null)
        {
            _logger.LogWarning(
                "No IPC client is registered to handle local media playback action request {Action} for {PlaybackId}.",
                action,
                request.PlaybackId);
            await ReportHandledMediaPlaybackActionAsync(
                requestId,
                success: false,
                failureReason: "CapabilityUnavailable",
                message: "No local media control client is connected.",
                cancellationToken).ConfigureAwait(false);
            return;
        }

        await NotifyIpcAsync("rift.onMediaPlaybackActionRequest", new
        {
            requestId,
            playbackId = request.PlaybackId,
            sourceDeviceId = request.SourceDeviceId,
            requestingDeviceId = request.RequestingDeviceId,
            action,
            positionMs = request.PositionMs,
            requestedAt = request.RequestedAt
        }).ConfigureAwait(false);
    }

    public async Task<ReportHandledMediaPlaybackActionResult> ReportHandledMediaPlaybackActionAsync(
        string requestId,
        bool success,
        string? failureReason,
        string? message,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (string.IsNullOrWhiteSpace(requestId))
        {
            throw new MediaPlaybackSyncFailureException("A media playback action request ID is required.", -32009);
        }

        failureReason = NormalizeFailureReason(
            success,
            failureReason,
            invalidErrorCode: -32602);

        PendingIncomingMediaPlaybackAction pending;
        lock (_gate)
        {
            if (!_pendingIncomingActionsByRequestId.Remove(requestId, out pending!))
            {
                throw new MediaPlaybackSyncFailureException($"Media playback action request '{requestId}' was not found.", -32009);
            }
            if (_pendingIncomingActionTimers.Remove(requestId, out var timer))
            {
                timer.Dispose();
            }
        }

        try
        {
            await SendIncomingActionResultAsync(
                pending,
                success,
                failureReason,
                message,
                cancellationToken).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            throw new MediaPlaybackSyncFailureException(
                $"Failed to send media playback action result: {ex.Message}",
                -32003);
        }

        await LogEventAsync(
            SecurityEventTypes.MediaPlaybackActioned,
            pending.RequestingDeviceId,
            success ? SecurityEventOutcome.Success : SecurityEventOutcome.Failure,
            failureReason,
            new Dictionary<string, object?>
            {
                ["playbackId"] = pending.PlaybackId,
                ["action"] = pending.Action,
                ["requestId"] = requestId,
                ["direction"] = "incoming"
            }).ConfigureAwait(false);

        return new ReportHandledMediaPlaybackActionResult
        {
            RequestId = requestId,
            PlaybackId = pending.PlaybackId,
            Action = pending.Action,
            Success = success
        };
    }

    private static string? NormalizeFailureReason(bool success, string? failureReason, int? invalidErrorCode)
    {
        if (failureReason is not null)
        {
            if (FailureReasons.Contains(failureReason))
            {
                return success ? null : failureReason;
            }
            if (invalidErrorCode.HasValue)
            {
                throw new MediaPlaybackSyncFailureException($"Invalid failureReason '{failureReason}'.", invalidErrorCode.Value);
            }
            return success ? null : "PeerRejected";
        }
        return success ? null : "PeerRejected";
    }

    private static bool IsActionAllowed(MediaPlaybackRecord playback, string action) => action switch
    {
        "play" => playback.CanPlay,
        "pause" => playback.CanPause,
        "togglePlayPause" => playback.CanPlay || playback.CanPause,
        "next" => playback.CanSkipNext,
        "previous" => playback.CanSkipPrevious,
        "seek" => playback.CanSeek,
        _ => false
    };

    private void EnsureActionAllowed(MediaPlaybackRecord playback, string action)
    {
        if (!IsActionAllowed(playback, action))
        {
            throw new MediaPlaybackSyncFailureException($"Mirrored playback '{playback.PlaybackId}' does not allow action '{action}'.", -32010);
        }
    }

    private void EnsurePeerCapability(string deviceId)
    {
        var presence = _presenceService.GetPeerPresence(deviceId);
        if (presence is null ||
            !string.Equals(presence.Status, "online", StringComparison.OrdinalIgnoreCase) ||
            !presence.Capabilities.Contains(RequiredCapability, StringComparer.Ordinal) ||
            !_transport.HasActiveSession(deviceId))
        {
            throw new MediaPlaybackSyncFailureException($"Capability '{RequiredCapability}' is not available for peer '{deviceId}'.", -32003);
        }
    }

    private static string NormalizeAction(string action, long? positionMs, bool allowSeekWithoutPosition = false)
    {
        var normalized = action switch
        {
            "play" => "play",
            "pause" => "pause",
            "togglePlayPause" => "togglePlayPause",
            "next" => "next",
            "previous" => "previous",
            "seek" => "seek",
            _ => throw new MediaPlaybackSyncFailureException($"Unknown media playback action '{action}'.", -32010)
        };

        if (normalized == "seek" && !allowSeekWithoutPosition && (!positionMs.HasValue || positionMs.Value < 0))
        {
            throw new MediaPlaybackSyncFailureException("A non-negative positionMs is required for seek.", -32602);
        }

        return normalized;
    }

    private static string ToOperationType(string action) => action switch
    {
        "play" => "media.play",
        "pause" => "media.pause",
        "togglePlayPause" => "media.toggle",
        "next" => "media.next",
        "previous" => "media.previous",
        "seek" => "media.seek",
        _ => "media.playback"
    };

    private static void ValidateRecord(MediaPlaybackRecord playback)
    {
        if (string.IsNullOrWhiteSpace(playback.PlaybackId) ||
            string.IsNullOrWhiteSpace(playback.SourceDeviceId) ||
            string.IsNullOrWhiteSpace(playback.AppId) ||
            string.IsNullOrWhiteSpace(playback.AppName) ||
            playback.PlaybackState is not ("playing" or "paused" or "stopped" or "buffering") ||
            !IsRfc3339UtcTimestamp(playback.UpdatedAt) ||
            playback.PositionMs < 0 ||
            playback.DurationMs < 0)
        {
            throw new InvalidOperationException("Mirrored media playback requires playbackId, sourceDeviceId, appId, appName, a valid playbackState, non-negative positionMs/durationMs, and an RFC 3339 updatedAt timestamp.");
        }
    }

    private static void ValidateOptionalAuditTimestamp(string? value, string fieldName)
    {
        if (value is not null && !IsRfc3339UtcTimestamp(value))
        {
            throw new MediaPlaybackSyncFailureException(
                $"{fieldName} must be a full RFC 3339 UTC timestamp.",
                -32602);
        }
    }

    private static bool IsRfc3339UtcTimestamp(string value) =>
        Rfc3339UtcTimestamp.IsMatch(value) &&
        DateTimeOffset.TryParse(
            value,
            CultureInfo.InvariantCulture,
            DateTimeStyles.None,
            out var timestamp) &&
        timestamp.Offset == TimeSpan.Zero;

    private MediaPlaybackRecord NormalizeLocalRecord(MediaPlaybackRecord playback)
    {
        return new MediaPlaybackRecord
        {
            PlaybackId = playback.PlaybackId,
            SourceDeviceId = string.IsNullOrWhiteSpace(playback.SourceDeviceId) ? _identityManager.GetDeviceId() : playback.SourceDeviceId,
            SourcePlatform = string.IsNullOrWhiteSpace(playback.SourcePlatform) ? DetectLocalPlatform() : playback.SourcePlatform,
            AppId = playback.AppId,
            AppName = playback.AppName,
            Title = playback.Title,
            Artist = playback.Artist,
            Album = playback.Album,
            Artwork = NormalizeArtwork(playback.Artwork),
            PlaybackState = playback.PlaybackState,
            PositionMs = playback.PositionMs,
            DurationMs = playback.DurationMs,
            CanPlay = playback.CanPlay,
            CanPause = playback.CanPause,
            CanSkipNext = playback.CanSkipNext,
            CanSkipPrevious = playback.CanSkipPrevious,
            CanSeek = playback.CanSeek,
            UpdatedAt = playback.UpdatedAt,
            IsRemoved = playback.IsRemoved,
            RemovedAt = playback.RemovedAt
        };
    }

    private static object CreatePlaybackPayload(MediaPlaybackRecord playback) => new
    {
        playbackId = playback.PlaybackId,
        sourceDeviceId = playback.SourceDeviceId,
        sourcePlatform = playback.SourcePlatform,
        appId = playback.AppId,
        appName = playback.AppName,
        title = playback.Title,
        artist = playback.Artist,
        album = playback.Album,
        artwork = playback.Artwork,
        playbackState = playback.PlaybackState,
        positionMs = playback.PositionMs,
        durationMs = playback.DurationMs,
        canPlay = playback.CanPlay,
        canPause = playback.CanPause,
        canSkipNext = playback.CanSkipNext,
        canSkipPrevious = playback.CanSkipPrevious,
        canSeek = playback.CanSeek,
        updatedAt = playback.UpdatedAt
    };

    private object CreateEnvelope(string type, object payload) => new
    {
        rift = "0.1-draft",
        type,
        messageId = Guid.NewGuid().ToString("D"),
        sourceDeviceId = _identityManager.GetDeviceId(),
        payload
    };

    private async Task<IReadOnlyList<string>> BroadcastAsync(string messageType, object payload, CancellationToken cancellationToken)
    {
        var sentTo = new List<string>();
        foreach (var peer in _presenceService.ListPeers())
        {
            if (!string.Equals(peer.Status, "online", StringComparison.OrdinalIgnoreCase) ||
                !peer.Capabilities.Contains(RequiredCapability, StringComparer.Ordinal) ||
                !_transport.HasActiveSession(peer.DeviceId))
            {
                continue;
            }

            try
            {
                var bytes = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(CreateEnvelope(messageType, payload)));
                await _transport.SendAsync(peer.DeviceId, bytes, cancellationToken).ConfigureAwait(false);
                sentTo.Add(peer.DeviceId);
            }
            catch (Exception ex)
            {
                _logger.LogWarning(ex, "Failed to send {MessageType} to {PeerDeviceId}.", messageType, peer.DeviceId);
            }
        }

        return sentTo;
    }

    private async Task SendIncomingActionResultAsync(
        PendingIncomingMediaPlaybackAction pending,
        bool success,
        string? failureReason,
        string? message,
        CancellationToken cancellationToken)
    {
        var envelope = CreateEnvelope(
            "media.playbackActionResult",
            new
            {
                playbackId = pending.PlaybackId,
                sourceDeviceId = pending.SourceDeviceId,
                requestingDeviceId = pending.RequestingDeviceId,
                action = pending.Action,
                success,
                failureReason,
                message
            });
        var bytes = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(envelope));
        await _transport.SendAsync(pending.RequestingDeviceId, bytes, cancellationToken).ConfigureAwait(false);
    }

    private async Task ExpireIncomingActionAsync(string requestId)
    {
        PendingIncomingMediaPlaybackAction? pending;
        lock (_gate)
        {
            if (!_pendingIncomingActionsByRequestId.Remove(requestId, out pending))
            {
                return;
            }
            if (_pendingIncomingActionTimers.Remove(requestId, out var timer))
            {
                timer.Dispose();
            }
        }

        try
        {
            await SendIncomingActionResultAsync(
                pending,
                success: false,
                failureReason: "Timeout",
                message: "The local media control client did not handle the request.",
                CancellationToken.None).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Failed to expire incoming media playback action {RequestId}.", requestId);
        }
    }

    private async Task NotifyIpcAsync(string method, object payload)
    {
        if (_ipcNotificationService is null)
        {
            return;
        }

        try
        {
            await _ipcNotificationService.NotifyAsync(method, payload).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Failed to notify IPC clients about {Method}.", method);
        }
    }

    private async Task LogEventAsync(string eventType, string? peerDeviceId, SecurityEventOutcome outcome, string? failureReason, IDictionary<string, object?> details)
    {
        try
        {
            await _securityEventLog.LogEventAsync(new SecurityEventRecord
            {
                EventType = eventType,
                Severity = outcome == SecurityEventOutcome.Failure ? SecurityEventSeverity.Warning : SecurityEventSeverity.Info,
                LocalDeviceId = _identityManager.GetDeviceId(),
                PeerDeviceId = peerDeviceId,
                Outcome = outcome,
                FailureReason = failureReason,
                Details = details.Where(entry => entry.Value is not null).ToDictionary(entry => entry.Key, entry => entry.Value!)
            }).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to persist media playback event {EventType}.", eventType);
        }
    }

    private static string GetPlaybackKey(string sourceDeviceId, string playbackId) => $"{sourceDeviceId}\n{playbackId}";

    private static string GetPendingActionKey(string sourceDeviceId, string playbackId, string action) => $"{sourceDeviceId}\n{playbackId}\n{action}";

    private static string DetectLocalPlatform() =>
        OperatingSystem.IsWindows() ? "windows" :
        OperatingSystem.IsMacOS() ? "macos" :
        OperatingSystem.IsLinux() ? "linux" :
        "unknown";

    private void TryTransitionActive(string operationId)
    {
        try
        {
            _operationService.TransitionOperation(operationId, OperationState.Active);
        }
        catch (OperationTransitionException)
        {
        }
    }

    private IReadOnlyDictionary<string, object?> CreateOperationDetails(MediaPlaybackRecord playback, string action, long? positionMs)
    {
        var details = new Dictionary<string, object?>
        {
            ["playbackId"] = playback.PlaybackId,
            ["sourceDeviceId"] = playback.SourceDeviceId,
            ["appId"] = playback.AppId,
            ["action"] = action
        };
        if (positionMs.HasValue)
        {
            details["positionMs"] = positionMs.Value;
        }

        return details;
    }

    private static IReadOnlyDictionary<string, object?>? NormalizeArtwork(IReadOnlyDictionary<string, object?>? artwork)
    {
        if (artwork is null)
        {
            return null;
        }

        return artwork.ToDictionary(
            entry => entry.Key,
            entry => NormalizeArtworkValue(entry.Value),
            StringComparer.Ordinal);
    }

    private static object? NormalizeArtworkValue(object? value) => value switch
    {
        JsonElement element => element.ValueKind switch
        {
            JsonValueKind.String => element.GetString(),
            JsonValueKind.Null => null,
            JsonValueKind.Object => element.EnumerateObject().ToDictionary(
                property => property.Name,
                property => NormalizeArtworkValue(property.Value),
                StringComparer.Ordinal),
            JsonValueKind.Array => element.EnumerateArray().Select(item => NormalizeArtworkValue(item)).ToArray(),
            _ => element.GetRawText()
        },
        JsonDocument document => NormalizeArtworkValue(document.RootElement),
        _ => value
    };

    private static MediaPlaybackRecord CloneRecord(MediaPlaybackRecord playback)
    {
        return new MediaPlaybackRecord
        {
            PlaybackId = playback.PlaybackId,
            SourceDeviceId = playback.SourceDeviceId,
            SourcePlatform = playback.SourcePlatform,
            AppId = playback.AppId,
            AppName = playback.AppName,
            Title = playback.Title,
            Artist = playback.Artist,
            Album = playback.Album,
            Artwork = NormalizeArtwork(playback.Artwork),
            PlaybackState = playback.PlaybackState,
            PositionMs = playback.PositionMs,
            DurationMs = playback.DurationMs,
            CanPlay = playback.CanPlay,
            CanPause = playback.CanPause,
            CanSkipNext = playback.CanSkipNext,
            CanSkipPrevious = playback.CanSkipPrevious,
            CanSeek = playback.CanSeek,
            UpdatedAt = playback.UpdatedAt,
            IsRemoved = playback.IsRemoved,
            RemovedAt = playback.RemovedAt
        };
    }

    private PendingPlaybackAction? RemovePendingAction(string operationId, string sourceDeviceId, string playbackId, string action)
    {
        lock (_gate)
        {
            _pendingActionsByOperationId.Remove(operationId, out var pending);
            var actionKey = GetPendingActionKey(sourceDeviceId, playbackId, action);
            if (_pendingActionKeys.GetValueOrDefault(actionKey) == operationId)
            {
                _pendingActionKeys.Remove(actionKey);
            }
            return pending;
        }
    }

    private void ExpirePendingAction(string operationId)
    {
        PendingPlaybackAction? pending;
        lock (_gate)
        {
            if (!_pendingActionsByOperationId.Remove(operationId, out pending))
            {
                return;
            }
            var actionKey = GetPendingActionKey(pending.SourceDeviceId, pending.PlaybackId, pending.Action);
            if (_pendingActionKeys.GetValueOrDefault(actionKey) == operationId)
            {
                _pendingActionKeys.Remove(actionKey);
            }
        }

        pending.ExpiryTimer?.Dispose();
        try
        {
            _operationService.TransitionOperation(operationId, OperationState.Expired, "Timeout");
        }
        catch (Exception ex)
        {
            // Timer-thread callback: an unhandled exception here would crash the
            // whole daemon process, so expiry bookkeeping failures are logged only.
            _logger.LogWarning(ex, "Failed to expire pending media playback action {OperationId}.", operationId);
        }
    }

    private sealed record PendingPlaybackAction(string OperationId, string PlaybackId, string SourceDeviceId, string Action)
    {
        public Timer? ExpiryTimer { get; set; }
    }
}
