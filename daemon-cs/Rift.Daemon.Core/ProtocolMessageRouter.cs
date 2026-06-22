using System.Text.Json;
using Rift.Daemon.Core.Interfaces;

namespace Rift.Daemon.Core;

public sealed class ProtocolMessageRouter(
    IPairingProtocolCoordinator pairingProtocolCoordinator,
    IPresenceService presenceService,
    IClipboardService clipboardService) : IProtocolMessageRouter
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

        EnsureProtectedMessageAllowed(session, messageType);

        if (string.Equals(messageType, "clipboard.offer", StringComparison.Ordinal))
        {
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
            var presencePayload = root.GetProperty("payload");
            var status = presencePayload.GetProperty("status").GetString() ?? "online";
            var lastSeenAt = presencePayload.TryGetProperty("lastSeenAt", out var lastSeenElement)
                ? lastSeenElement.GetString()
                : null;
            var capabilities = presencePayload.TryGetProperty("capabilities", out var capabilitiesElement)
                ? capabilitiesElement.EnumerateArray().Select(element => element.GetString() ?? string.Empty).Where(value => value.Length > 0).ToArray()
                : [];

            presenceService.UpdatePeerPresence(peerDeviceId, status, lastSeenAt, capabilities);
        }
    }

    private static void EnsureProtectedMessageAllowed(SessionPeerContext session, string messageType)
    {
        if (!session.AllowsProtectedTraffic)
        {
            throw new UnauthorizedAccessException($"Session for '{session.PeerDeviceId}' is not authorized for protected traffic.");
        }

        string? requiredCapability = messageType switch
        {
            "presence.update" => "presence.basic",
            "clipboard.offer" or "clipboard.fetchRequest" or "clipboard.fetchResponse" or "clipboard.fetchReject" => "clipboard.offer_fetch",
            _ when messageType.StartsWith("operation.", StringComparison.Ordinal) => "operation.lifecycle",
            _ => null
        };

        if (requiredCapability is null || session.HasCapability(requiredCapability))
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
