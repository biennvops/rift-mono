using System.Text;
using System.Text.Json;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;
using Rift.Daemon.Core.Interfaces;

namespace Rift.Daemon.Core;

public sealed class MediaPlaybackSyncService : IMediaPlaybackSyncService
{
    private const string RequiredCapability = "media.playback";
    private static readonly StringComparer Comparer = StringComparer.Ordinal;
    private readonly Lock _gate = new();
    private readonly ITransport _transport;
    private readonly IPresenceService _presenceService;
    private readonly IIdentityManager _identityManager;
    private readonly IOperationService _operationService;
    private readonly ISecurityEventLog _securityEventLog;
    private readonly IIpcNotificationService? _ipcNotificationService;
    private readonly ILogger<MediaPlaybackSyncService> _logger;
    private readonly Dictionary<string, MediaPlaybackRecord> _playbacks = new(Comparer);
    private readonly Dictionary<string, PendingPlaybackAction> _pendingActionsByOperationId = new(Comparer);
    private readonly Dictionary<string, string> _pendingActionKeys = new(Comparer);

    public MediaPlaybackSyncService(
        ITransport transport,
        IPresenceService presenceService,
        IIdentityManager identityManager,
        IOperationService operationService,
        ISecurityEventLog securityEventLog,
        IIpcNotificationService? ipcNotificationService = null,
        ILogger<MediaPlaybackSyncService>? logger = null)
    {
        _transport = transport;
        _presenceService = presenceService;
        _identityManager = identityManager;
        _operationService = operationService;
        _securityEventLog = securityEventLog;
        _ipcNotificationService = ipcNotificationService;
        _logger = logger ?? NullLogger<MediaPlaybackSyncService>.Instance;
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

    public Task<MediaPlaybackRecord> GetMediaPlaybackAsync(string playbackId, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (string.IsNullOrWhiteSpace(playbackId))
        {
            throw new MediaPlaybackSyncFailureException("A playback ID is required.", -32009);
        }

        lock (_gate)
        {
            var record = _playbacks.Values
                .Where(playback => !playback.IsRemoved)
                .FirstOrDefault(playback => string.Equals(playback.PlaybackId, playbackId, StringComparison.Ordinal));
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
                normalized,
                cancellationToken).ConfigureAwait(false)
        };
    }

    public async Task<PerformMediaPlaybackActionResult> PerformMediaPlaybackActionAsync(
        string playbackId,
        string action,
        long? positionMs,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (string.IsNullOrWhiteSpace(playbackId))
        {
            throw new MediaPlaybackSyncFailureException("A playback ID is required.", -32009);
        }

        var normalizedAction = NormalizeAction(action, positionMs);
        MediaPlaybackRecord playback;
        lock (_gate)
        {
            playback = _playbacks.Values
                .Where(record => !record.IsRemoved)
                .FirstOrDefault(record => string.Equals(record.PlaybackId, playbackId, StringComparison.Ordinal))
                ?? throw new MediaPlaybackSyncFailureException($"Mirrored playback '{playbackId}' was not found.", -32009);
        }

        EnsureActionAllowed(playback, normalizedAction);
        EnsurePeerCapability(playback.SourceDeviceId);

        var operationId = Guid.NewGuid().ToString("D");
        _operationService.CreateOperation(operationId, ToOperationType(normalizedAction), _identityManager.GetDeviceId(), playback.SourceDeviceId);
        _operationService.TransitionOperation(operationId, OperationState.Pending, details: CreateOperationDetails(playback, normalizedAction, positionMs));
        lock (_gate)
        {
            _pendingActionsByOperationId[operationId] = new PendingPlaybackAction(operationId, playback.PlaybackId, playback.SourceDeviceId, normalizedAction);
            _pendingActionKeys[GetPendingActionKey(playback.SourceDeviceId, playback.PlaybackId, normalizedAction)] = operationId;
        }
        _operationService.TransitionOperation(operationId, OperationState.Dispatched);

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
            RemovePendingAction(operationId, playback.SourceDeviceId, playback.PlaybackId, normalizedAction);
            _operationService.TransitionOperation(operationId, OperationState.Failed, "PeerUnreachable");
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
            throw new InvalidOperationException("media.playbackActionResult requestingDeviceId did not match the local device identity.");
        }

        var action = NormalizeAction(result.Action, null, allowSeekWithoutPosition: true);
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
                string.IsNullOrWhiteSpace(result.FailureReason) ? "Rejected" : result.FailureReason,
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
            failureReason = result.FailureReason,
            message = result.Message
        }).ConfigureAwait(false);
        await LogEventAsync(SecurityEventTypes.MediaPlaybackActioned, result.SourceDeviceId, result.Success ? SecurityEventOutcome.Success : SecurityEventOutcome.Failure, result.FailureReason, new Dictionary<string, object?>
        {
            ["playbackId"] = result.PlaybackId,
            ["action"] = action,
            ["operationId"] = pending.OperationId
        }).ConfigureAwait(false);
    }

    private void EnsureActionAllowed(MediaPlaybackRecord playback, string action)
    {
        var allowed = action switch
        {
            "play" => playback.CanPlay,
            "pause" => playback.CanPause,
            "togglePlayPause" => playback.CanPlay || playback.CanPause,
            "next" => playback.CanSkipNext,
            "previous" => playback.CanSkipPrevious,
            "seek" => playback.CanSeek,
            _ => false
        };

        if (!allowed)
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
            string.IsNullOrWhiteSpace(playback.PlaybackState) ||
            string.IsNullOrWhiteSpace(playback.UpdatedAt) ||
            playback.PositionMs < 0 ||
            playback.DurationMs < 0)
        {
            throw new InvalidOperationException("Mirrored media playback requires playbackId, sourceDeviceId, appId, appName, playbackState, non-negative positionMs/durationMs, and updatedAt.");
        }
    }

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
            Artwork = playback.Artwork is null ? null : new Dictionary<string, object?>(playback.Artwork),
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
            Artwork = playback.Artwork is null ? null : new Dictionary<string, object?>(playback.Artwork),
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

    private void RemovePendingAction(string operationId, string sourceDeviceId, string playbackId, string action)
    {
        lock (_gate)
        {
            _pendingActionsByOperationId.Remove(operationId);
            _pendingActionKeys.Remove(GetPendingActionKey(sourceDeviceId, playbackId, action));
        }
    }

    private sealed record PendingPlaybackAction(string OperationId, string PlaybackId, string SourceDeviceId, string Action);
}
