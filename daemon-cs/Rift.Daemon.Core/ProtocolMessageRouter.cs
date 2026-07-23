using System.Text.Json;
using Rift.Daemon.Core.Interfaces;
using Rift.Daemon.Core.Networking;

namespace Rift.Daemon.Core;

public sealed class ProtocolMessageRouter(
    IPairingProtocolCoordinator pairingProtocolCoordinator,
    IPresenceService presenceService,
    IClipboardService clipboardService,
    IFileTransferService fileTransferService,
    IMediaPlaybackSyncService mediaPlaybackSyncService,
    INotificationSyncService notificationSyncService) : IProtocolMessageRouter
{
    public async Task HandleMessageAsync(SessionPeerContext session, ReadOnlyMemory<byte> payload, CancellationToken cancellationToken)
    {
        string? messageType = null;
        string? messageId = null;
        try
        {
            using (var document = JsonDocument.Parse(payload))
            {
                var root = document.RootElement;
                messageType = root.TryGetProperty("type", out var typeElement) && typeElement.ValueKind == JsonValueKind.String
                    ? typeElement.GetString()
                    : null;
                messageId = root.TryGetProperty("messageId", out var idElement) && idElement.ValueKind == JsonValueKind.String
                    ? idElement.GetString()
                    : null;
            }

            await HandleValidatedMessageAsync(session, payload, cancellationToken).ConfigureAwait(false);
        }
        catch (Exception ex) when (messageType?.StartsWith("media.playback", StringComparison.Ordinal) == true && IsMediaMessageError(ex))
        {
            var failureReason = ex switch
            {
                UnauthorizedAccessException when ex.Message.Contains("requires negotiated capability", StringComparison.Ordinal) => "CapabilityUnavailable",
                UnauthorizedAccessException => "Unauthorized",
                MediaPlaybackSyncFailureException { ErrorCode: -32010 } => "ProtocolError",
                _ => "MalformedMessage"
            };
            await mediaPlaybackSyncService.SendPeerErrorAsync(
                session.PeerDeviceId,
                failureReason,
                messageId,
                ex.Message,
                cancellationToken).ConfigureAwait(false);
        }
    }

    private async Task HandleValidatedMessageAsync(SessionPeerContext session, ReadOnlyMemory<byte> payload, CancellationToken cancellationToken)
    {
        var peerDeviceId = session.PeerDeviceId;
        using var document = JsonDocument.Parse(payload);
        var root = document.RootElement;
        var messageType = root.GetProperty("type").GetString();
        var sourceDeviceId = root.GetProperty("sourceDeviceId").GetString() ?? string.Empty;

        if (string.IsNullOrWhiteSpace(messageType))
        {
            return;
        }

        EnsureEnvelopeIdentityMatches(peerDeviceId, sourceDeviceId, messageType);
        presenceService.ObservePeerMessage(peerDeviceId);

        if (messageType.StartsWith("pairing.", StringComparison.Ordinal))
        {
            await pairingProtocolCoordinator.HandleMessageAsync(peerDeviceId, payload, cancellationToken);
            return;
        }

        if (string.Equals(messageType, "trust.remove", StringComparison.Ordinal))
        {
            if (!session.AllowsProtectedTraffic)
            {
                throw new UnauthorizedAccessException($"Session for '{session.PeerDeviceId}' is not authorized for protected traffic.");
            }

            await pairingProtocolCoordinator.HandleMessageAsync(peerDeviceId, payload, cancellationToken);
            return;
        }

        if (string.Equals(messageType, "clipboard.offer", StringComparison.Ordinal))
        {
            EnsureProtectedMessageAllowed(session, "clipboard.offer_fetch", messageType);
            var clipboardPayload = root.GetProperty("payload");
            await clipboardService.HandleOfferReceivedAsync(new ReceivedClipboardOffer
            {
                DeviceId = peerDeviceId,
                PayloadSourceDeviceId = clipboardPayload.GetProperty("sourceDeviceId").GetString() ?? string.Empty,
                OfferId = clipboardPayload.GetProperty("offerId").GetString() ?? string.Empty,
                ContentType = clipboardPayload.GetProperty("contentType").GetString() ?? string.Empty,
                ByteSize = clipboardPayload.GetProperty("byteSize").GetInt64(),
                Sha256 = clipboardPayload.GetProperty("sha256").GetString() ?? string.Empty,
                ExpiresInMs = clipboardPayload.GetProperty("expiresInMs").GetInt64(),
                RequiredCapability = clipboardPayload.GetProperty("requiredCapability").GetString() ?? string.Empty,
                OfferSequence = clipboardPayload.GetProperty("offerSequence").GetInt64()
            });
            return;
        }

        if (string.Equals(messageType, "clipboard.fetchRequest", StringComparison.Ordinal))
        {
            EnsureProtectedMessageAllowed(session, "clipboard.offer_fetch", messageType);
            var clipboardPayload = root.GetProperty("payload");
            await clipboardService.HandleFetchRequestAsync(
                peerDeviceId,
                clipboardPayload.GetProperty("offerId").GetString() ?? string.Empty,
                clipboardPayload.GetProperty("requestingDeviceId").GetString() ?? string.Empty,
                cancellationToken);
            return;
        }

        if (string.Equals(messageType, "clipboard.fetchResponse", StringComparison.Ordinal))
        {
            EnsureProtectedMessageAllowed(session, "clipboard.offer_fetch", messageType);
            var clipboardPayload = root.GetProperty("payload");
            await clipboardService.HandleFetchResponseAsync(
                peerDeviceId,
                clipboardPayload.GetProperty("offerId").GetString() ?? string.Empty,
                clipboardPayload.GetProperty("contentBase64").GetString() ?? string.Empty,
                clipboardPayload.GetProperty("byteSize").GetInt64(),
                clipboardPayload.GetProperty("sha256").GetString() ?? string.Empty,
                cancellationToken);
            return;
        }

        if (string.Equals(messageType, "clipboard.fetchReject", StringComparison.Ordinal))
        {
            EnsureProtectedMessageAllowed(session, "clipboard.offer_fetch", messageType);
            var clipboardPayload = root.GetProperty("payload");
            await clipboardService.HandleFetchRejectAsync(
                peerDeviceId,
                clipboardPayload.GetProperty("offerId").GetString() ?? string.Empty,
                clipboardPayload.GetProperty("failureReason").GetString() ?? string.Empty,
                clipboardPayload.TryGetProperty("message", out var messageElement) ? messageElement.GetString() : null,
                cancellationToken);
            return;
        }

        if (string.Equals(messageType, "presence.update", StringComparison.Ordinal))
        {
            EnsureProtectedMessageAllowed(session, SessionHeartbeatManager.PresenceBasicCapability, messageType);
            var presencePayload = root.GetProperty("payload");
            var status = presencePayload.GetProperty("status").GetString() ?? "online";
            var lastSeenAt = presencePayload.TryGetProperty("lastSeenAt", out var lastSeenElement)
                ? lastSeenElement.GetString()
                : null;
            var capabilities = presencePayload.TryGetProperty("capabilities", out var capabilitiesElement)
                ? capabilitiesElement.EnumerateArray().Select(element => element.GetString() ?? string.Empty).Where(value => value.Length > 0).ToArray()
                : [];

            presenceService.UpdatePeerPresence(peerDeviceId, status, lastSeenAt, capabilities);
            return;
        }

        if (string.Equals(messageType, "notification.posted", StringComparison.Ordinal))
        {
            EnsureProtectedMessageAllowed(session, "notification.sync", messageType);
            var notificationPayload = root.GetProperty("payload");
            EnsureEnvelopeIdentityMatches(peerDeviceId, notificationPayload.GetProperty("sourceDeviceId").GetString() ?? string.Empty, messageType);
            await notificationSyncService.HandleNotificationPostedAsync(
                ParseNotificationRecord(notificationPayload),
                cancellationToken);
            return;
        }

        if (string.Equals(messageType, "media.playbackPosted", StringComparison.Ordinal))
        {
            EnsureProtectedMessageAllowed(session, "media.playback", messageType);
            var mediaPayload = root.GetProperty("payload");
            EnsureEnvelopeIdentityMatches(peerDeviceId, mediaPayload.GetProperty("sourceDeviceId").GetString() ?? string.Empty, messageType);
            await mediaPlaybackSyncService.HandleMediaPlaybackPostedAsync(ParseMediaPlaybackRecord(mediaPayload), cancellationToken);
            return;
        }

        if (string.Equals(messageType, "media.playbackUpdated", StringComparison.Ordinal))
        {
            EnsureProtectedMessageAllowed(session, "media.playback", messageType);
            var mediaPayload = root.GetProperty("payload");
            EnsureEnvelopeIdentityMatches(peerDeviceId, mediaPayload.GetProperty("sourceDeviceId").GetString() ?? string.Empty, messageType);
            await mediaPlaybackSyncService.HandleMediaPlaybackUpdatedAsync(ParseMediaPlaybackRecord(mediaPayload), cancellationToken);
            return;
        }

        if (string.Equals(messageType, "media.playbackRemoved", StringComparison.Ordinal))
        {
            EnsureProtectedMessageAllowed(session, "media.playback", messageType);
            var mediaPayload = root.GetProperty("payload");
            var payloadSourceDeviceId = mediaPayload.GetProperty("sourceDeviceId").GetString() ?? string.Empty;
            EnsureEnvelopeIdentityMatches(peerDeviceId, payloadSourceDeviceId, messageType);
            await mediaPlaybackSyncService.HandleMediaPlaybackRemovedAsync(new MediaPlaybackRemovedRecord
            {
                PlaybackId = mediaPayload.GetProperty("playbackId").GetString() ?? string.Empty,
                SourceDeviceId = payloadSourceDeviceId,
                RemovedAt = mediaPayload.TryGetProperty("removedAt", out var removedAtElement) ? removedAtElement.GetString() : null
            }, cancellationToken);
            return;
        }

        if (string.Equals(messageType, "media.playbackActionResult", StringComparison.Ordinal))
        {
            EnsureProtectedMessageAllowed(session, "media.playback", messageType);
            var mediaPayload = root.GetProperty("payload");
            var payloadSourceDeviceId = mediaPayload.GetProperty("sourceDeviceId").GetString() ?? string.Empty;
            EnsureEnvelopeIdentityMatches(peerDeviceId, payloadSourceDeviceId, messageType);
            await mediaPlaybackSyncService.HandleMediaPlaybackActionResultAsync(new MediaPlaybackActionResultRecord
            {
                PlaybackId = mediaPayload.GetProperty("playbackId").GetString() ?? string.Empty,
                SourceDeviceId = payloadSourceDeviceId,
                RequestingDeviceId = mediaPayload.GetProperty("requestingDeviceId").GetString() ?? string.Empty,
                Action = mediaPayload.GetProperty("action").GetString() ?? string.Empty,
                Success = mediaPayload.GetProperty("success").GetBoolean(),
                FailureReason = mediaPayload.TryGetProperty("failureReason", out var failureReasonElement) ? failureReasonElement.GetString() : null,
                Message = mediaPayload.TryGetProperty("message", out var messageElement) ? messageElement.GetString() : null
            }, cancellationToken);
            return;
        }

        if (string.Equals(messageType, "media.playbackActionRequest", StringComparison.Ordinal))
        {
            EnsureProtectedMessageAllowed(session, "media.playback", messageType);
            var mediaPayload = root.GetProperty("payload");
            var payloadSourceDeviceId = mediaPayload.GetProperty("sourceDeviceId").GetString() ?? string.Empty;
            var requestingDeviceId = mediaPayload.GetProperty("requestingDeviceId").GetString() ?? string.Empty;
            EnsureEnvelopeIdentityMatches(peerDeviceId, requestingDeviceId, messageType);
            await mediaPlaybackSyncService.HandleMediaPlaybackActionRequestAsync(new MediaPlaybackActionRequestRecord
            {
                PlaybackId = mediaPayload.GetProperty("playbackId").GetString() ?? string.Empty,
                SourceDeviceId = payloadSourceDeviceId,
                RequestingDeviceId = requestingDeviceId,
                Action = mediaPayload.GetProperty("action").GetString() ?? string.Empty,
                PositionMs = mediaPayload.TryGetProperty("positionMs", out var positionElement) && positionElement.ValueKind == JsonValueKind.Number
                    ? positionElement.GetInt64()
                    : null,
                RequestedAt = mediaPayload.TryGetProperty("requestedAt", out var requestedAtElement) ? requestedAtElement.GetString() : null
            }, cancellationToken);
            return;
        }

        if (string.Equals(messageType, "notification.updated", StringComparison.Ordinal))
        {
            EnsureProtectedMessageAllowed(session, "notification.sync", messageType);
            var notificationPayload = root.GetProperty("payload");
            EnsureEnvelopeIdentityMatches(peerDeviceId, notificationPayload.GetProperty("sourceDeviceId").GetString() ?? string.Empty, messageType);
            await notificationSyncService.HandleNotificationUpdatedAsync(
                ParseNotificationRecord(notificationPayload),
                cancellationToken);
            return;
        }

        if (string.Equals(messageType, "notification.removed", StringComparison.Ordinal))
        {
            EnsureProtectedMessageAllowed(session, "notification.sync", messageType);
            var notificationPayload = root.GetProperty("payload");
            var payloadSourceDeviceId = notificationPayload.GetProperty("sourceDeviceId").GetString() ?? string.Empty;
            EnsureEnvelopeIdentityMatches(peerDeviceId, payloadSourceDeviceId, messageType);
            await notificationSyncService.HandleNotificationRemovedAsync(
                new NotificationRemovedRecord
                {
                    NotificationId = notificationPayload.GetProperty("notificationId").GetString() ?? string.Empty,
                    SourceDeviceId = payloadSourceDeviceId,
                    RemovedAt = notificationPayload.TryGetProperty("removedAt", out var removedAtElement)
                        ? removedAtElement.GetString()
                        : null
                },
                cancellationToken);
            return;
        }

        if (string.Equals(messageType, "notification.actionResult", StringComparison.Ordinal))
        {
            EnsureProtectedMessageAllowed(session, "notification.sync", messageType);
            var notificationPayload = root.GetProperty("payload");
            var payloadSourceDeviceId = notificationPayload.GetProperty("sourceDeviceId").GetString() ?? string.Empty;
            EnsureEnvelopeIdentityMatches(peerDeviceId, payloadSourceDeviceId, messageType);
            await notificationSyncService.HandleNotificationActionResultAsync(
                new NotificationActionResultRecord
                {
                    NotificationId = notificationPayload.GetProperty("notificationId").GetString() ?? string.Empty,
                    SourceDeviceId = payloadSourceDeviceId,
                    RequestingDeviceId = notificationPayload.GetProperty("requestingDeviceId").GetString() ?? string.Empty,
                    Action = notificationPayload.GetProperty("action").GetString() ?? string.Empty,
                    Success = notificationPayload.GetProperty("success").GetBoolean(),
                    FailureReason = notificationPayload.TryGetProperty("failureReason", out var failureReasonElement)
                        ? failureReasonElement.GetString()
                        : null,
                    Message = notificationPayload.TryGetProperty("message", out var actionMessageElement)
                        ? actionMessageElement.GetString()
                        : null
                },
                cancellationToken);
            return;
        }

        if (string.Equals(messageType, "file.offer", StringComparison.Ordinal))
        {
            EnsureProtectedMessageAllowed(session, "file.transfer", messageType);
            var filePayload = root.GetProperty("payload");
            await fileTransferService.HandleOfferReceivedAsync(new ReceivedFileOffer
            {
                DeviceId = peerDeviceId,
                PayloadSourceDeviceId = filePayload.GetProperty("sourceDeviceId").GetString() ?? string.Empty,
                TransferId = filePayload.GetProperty("transferId").GetString() ?? string.Empty,
                FileName = filePayload.GetProperty("fileName").GetString() ?? string.Empty,
                MediaType = filePayload.GetProperty("mediaType").GetString() ?? "application/octet-stream",
                ByteSize = filePayload.GetProperty("byteSize").GetInt64(),
                Sha256 = filePayload.GetProperty("sha256").GetString() ?? string.Empty,
                ChunkSize = filePayload.GetProperty("chunkSize").GetInt32(),
                ChunkCount = filePayload.GetProperty("chunkCount").GetInt32(),
                ExpiresInMs = filePayload.GetProperty("expiresInMs").GetInt64(),
                RequiredCapability = filePayload.GetProperty("requiredCapability").GetString() ?? string.Empty
            }, cancellationToken);
            return;
        }

        if (string.Equals(messageType, "file.accept", StringComparison.Ordinal))
        {
            EnsureProtectedMessageAllowed(session, "file.transfer", messageType);
            var filePayload = root.GetProperty("payload");
            await fileTransferService.HandleAcceptReceivedAsync(
                peerDeviceId,
                filePayload.GetProperty("transferId").GetString() ?? string.Empty,
                filePayload.GetProperty("receivingDeviceId").GetString() ?? string.Empty,
                filePayload.TryGetProperty("chunkSize", out var chunkSizeElement) ? chunkSizeElement.GetInt32() : null,
                cancellationToken);
            return;
        }

        if (string.Equals(messageType, "file.reject", StringComparison.Ordinal))
        {
            EnsureProtectedMessageAllowed(session, "file.transfer", messageType);
            var filePayload = root.GetProperty("payload");
            await fileTransferService.HandleRejectReceivedAsync(
                peerDeviceId,
                filePayload.GetProperty("transferId").GetString() ?? string.Empty,
                filePayload.GetProperty("failureReason").GetString() ?? string.Empty,
                filePayload.TryGetProperty("message", out var rejectMessageElement) ? rejectMessageElement.GetString() : null,
                cancellationToken);
            return;
        }

        if (string.Equals(messageType, "file.chunk", StringComparison.Ordinal))
        {
            EnsureProtectedMessageAllowed(session, "file.transfer", messageType);
            var filePayload = root.GetProperty("payload");
            await fileTransferService.HandleChunkReceivedAsync(
                peerDeviceId,
                filePayload.GetProperty("transferId").GetString() ?? string.Empty,
                filePayload.GetProperty("chunkIndex").GetInt32(),
                filePayload.GetProperty("offset").GetInt64(),
                filePayload.GetProperty("byteSize").GetInt32(),
                filePayload.GetProperty("chunkSha256").GetString() ?? string.Empty,
                filePayload.GetProperty("contentBase64").GetString() ?? string.Empty,
                filePayload.GetProperty("isLastChunk").GetBoolean(),
                cancellationToken);
            return;
        }

        if (string.Equals(messageType, "file.complete", StringComparison.Ordinal))
        {
            EnsureProtectedMessageAllowed(session, "file.transfer", messageType);
            var filePayload = root.GetProperty("payload");
            await fileTransferService.HandleCompleteReceivedAsync(
                peerDeviceId,
                filePayload.GetProperty("transferId").GetString() ?? string.Empty,
                filePayload.GetProperty("byteSize").GetInt64(),
                filePayload.GetProperty("sha256").GetString() ?? string.Empty,
                filePayload.GetProperty("chunkCount").GetInt32(),
                cancellationToken);
            return;
        }

        if (string.Equals(messageType, "file.cancel", StringComparison.Ordinal))
        {
            EnsureProtectedMessageAllowed(session, "file.transfer", messageType);
            var filePayload = root.GetProperty("payload");
            await fileTransferService.HandleCancelReceivedAsync(
                peerDeviceId,
                filePayload.GetProperty("transferId").GetString() ?? string.Empty,
                filePayload.GetProperty("failureReason").GetString() ?? string.Empty,
                filePayload.TryGetProperty("message", out var cancelMessageElement) ? cancelMessageElement.GetString() : null,
                cancellationToken);
            return;
        }

        if (string.Equals(messageType, "file.resume", StringComparison.Ordinal))
        {
            EnsureProtectedMessageAllowed(session, "file.transfer", messageType);
            var filePayload = root.GetProperty("payload");
            await fileTransferService.HandleResumeReceivedAsync(
                peerDeviceId,
                filePayload.GetProperty("transferId").GetString() ?? string.Empty,
                filePayload.GetProperty("receivingDeviceId").GetString() ?? string.Empty,
                filePayload.GetProperty("nextChunkIndex").GetInt32(),
                filePayload.GetProperty("offset").GetInt64(),
                cancellationToken);
            return;
        }

        if (messageType.StartsWith("operation.", StringComparison.Ordinal))
        {
            EnsureProtectedMessageAllowed(session, "operation.lifecycle", messageType);
            throw new InvalidOperationException($"Unsupported protected message type '{messageType}'.");
        }

        if (messageType.StartsWith("security.", StringComparison.Ordinal))
        {
            EnsureProtectedMessageAllowed(session, "security.event_log", messageType);
            throw new InvalidOperationException($"Unsupported protected message type '{messageType}'.");
        }
    }

    private static void EnsureProtectedMessageAllowed(SessionPeerContext session, string requiredCapability, string messageType)
    {
        if (!session.AllowsProtectedTraffic)
        {
            throw new UnauthorizedAccessException($"Session for '{session.PeerDeviceId}' is not authorized for protected traffic.");
        }

        if (session.HasCapability(requiredCapability))
        {
            return;
        }

        throw new UnauthorizedAccessException($"{messageType} requires negotiated capability '{requiredCapability}'.");
    }

    private static void EnsureEnvelopeIdentityMatches(string authenticatedDeviceId, string sourceDeviceId, string messageType)
    {
        if (string.Equals(authenticatedDeviceId, sourceDeviceId, StringComparison.Ordinal))
        {
            return;
        }

        throw new UnauthorizedAccessException($"{messageType} sourceDeviceId did not match the authenticated peer identity.");
    }

    private static NotificationSyncRecord ParseNotificationRecord(JsonElement notificationPayload)
    {
        IReadOnlyDictionary<string, object?>? icon = null;
        if (notificationPayload.TryGetProperty("icon", out var iconElement) &&
            iconElement.ValueKind == JsonValueKind.Object)
        {
            icon = JsonSerializer.Deserialize<Dictionary<string, object?>>(iconElement.GetRawText());
        }

        return new NotificationSyncRecord
        {
            NotificationId = notificationPayload.GetProperty("notificationId").GetString() ?? string.Empty,
            SourceDeviceId = notificationPayload.GetProperty("sourceDeviceId").GetString() ?? string.Empty,
            SourcePlatform = notificationPayload.TryGetProperty("sourcePlatform", out var sourcePlatformElement)
                ? sourcePlatformElement.GetString()
                : null,
            PackageName = notificationPayload.GetProperty("packageName").GetString() ?? string.Empty,
            AppName = notificationPayload.GetProperty("appName").GetString() ?? string.Empty,
            Title = notificationPayload.TryGetProperty("title", out var titleElement) ? titleElement.GetString() : null,
            BodyPreview = notificationPayload.TryGetProperty("bodyPreview", out var bodyPreviewElement) ? bodyPreviewElement.GetString() : null,
            PostedAt = notificationPayload.GetProperty("postedAt").GetString() ?? string.Empty,
            IsDismissible = notificationPayload.GetProperty("isDismissible").GetBoolean(),
            IsOpenable = notificationPayload.GetProperty("isOpenable").GetBoolean(),
            Icon = icon
        };
    }

    private static Dictionary<string, object?>? ParseObject(JsonElement element)
    {
        if (element.ValueKind != JsonValueKind.Object)
        {
            return null;
        }

        var result = new Dictionary<string, object?>(StringComparer.Ordinal);
        foreach (var property in element.EnumerateObject())
        {
            result[property.Name] = ParseValue(property.Value);
        }

        return result;
    }

    private static object? ParseValue(JsonElement element) => element.ValueKind switch
    {
        JsonValueKind.Object => ParseObject(element),
        JsonValueKind.Array => element.EnumerateArray().Select(ParseValue).ToArray(),
        JsonValueKind.String => element.GetString(),
        JsonValueKind.Number when element.TryGetInt64(out var intValue) => intValue,
        JsonValueKind.Number => element.GetDouble(),
        JsonValueKind.True => true,
        JsonValueKind.False => false,
        JsonValueKind.Null or JsonValueKind.Undefined => null,
        _ => element.GetRawText()
    };

    private static bool IsMediaMessageError(Exception exception) =>
        exception is JsonException or KeyNotFoundException or InvalidOperationException or FormatException or MediaPlaybackSyncFailureException or UnauthorizedAccessException;

    private static MediaPlaybackRecord ParseMediaPlaybackRecord(JsonElement mediaPayload)
    {
        return new MediaPlaybackRecord
        {
            PlaybackId = mediaPayload.GetProperty("playbackId").GetString() ?? string.Empty,
            SourceDeviceId = mediaPayload.GetProperty("sourceDeviceId").GetString() ?? string.Empty,
            SourcePlatform = mediaPayload.TryGetProperty("sourcePlatform", out var platformElement) ? platformElement.GetString() : null,
            AppId = mediaPayload.GetProperty("appId").GetString() ?? string.Empty,
            AppName = mediaPayload.GetProperty("appName").GetString() ?? string.Empty,
            Title = mediaPayload.TryGetProperty("title", out var titleElement) ? titleElement.GetString() : null,
            Artist = mediaPayload.TryGetProperty("artist", out var artistElement) ? artistElement.GetString() : null,
            Album = mediaPayload.TryGetProperty("album", out var albumElement) ? albumElement.GetString() : null,
            Artwork = mediaPayload.TryGetProperty("artwork", out var artworkElement)
                ? ParseObject(artworkElement)
                : null,
            PlaybackState = mediaPayload.GetProperty("playbackState").GetString() ?? string.Empty,
            PositionMs = mediaPayload.GetProperty("positionMs").GetInt64(),
            DurationMs = mediaPayload.TryGetProperty("durationMs", out var durationElement) ? durationElement.GetInt64() : null,
            CanPlay = mediaPayload.GetProperty("canPlay").GetBoolean(),
            CanPause = mediaPayload.GetProperty("canPause").GetBoolean(),
            CanSkipNext = mediaPayload.GetProperty("canSkipNext").GetBoolean(),
            CanSkipPrevious = mediaPayload.GetProperty("canSkipPrevious").GetBoolean(),
            CanSeek = mediaPayload.GetProperty("canSeek").GetBoolean(),
            UpdatedAt = mediaPayload.GetProperty("updatedAt").GetString() ?? string.Empty
        };
    }
}
