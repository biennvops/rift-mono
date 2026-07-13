using System.Text.Json;
using Rift.Daemon.Core.Interfaces;
using Rift.Daemon.Core.Networking;

namespace Rift.Daemon.Core;

public sealed class ProtocolMessageRouter(
    IPairingProtocolCoordinator pairingProtocolCoordinator,
    IPresenceService presenceService,
    IClipboardService clipboardService,
    IFileTransferService fileTransferService) : IProtocolMessageRouter
{
    public async Task HandleMessageAsync(SessionPeerContext session, ReadOnlyMemory<byte> payload, CancellationToken cancellationToken)
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
}
