using System.Text.Json;
using Rift.Daemon.Core.Interfaces;

namespace Rift.Daemon.Core;

public sealed class ProtocolMessageRouter(
    IPairingProtocolCoordinator pairingProtocolCoordinator,
    IPresenceService presenceService,
    IClipboardService clipboardService) : IProtocolMessageRouter
{
    public async Task HandleMessageAsync(string peerDeviceId, ReadOnlyMemory<byte> payload, CancellationToken cancellationToken)
    {
        presenceService.ObservePeerMessage(peerDeviceId);

        using var document = JsonDocument.Parse(payload);
        var root = document.RootElement;
        var messageType = root.GetProperty("type").GetString();

        if (string.IsNullOrWhiteSpace(messageType))
        {
            return;
        }

        if (messageType.StartsWith("pairing.", StringComparison.Ordinal))
        {
            await pairingProtocolCoordinator.HandleMessageAsync(peerDeviceId, payload, cancellationToken);
            return;
        }

        if (string.Equals(messageType, "clipboard.offer", StringComparison.Ordinal))
        {
            var clipboardPayload = root.GetProperty("payload");
            await clipboardService.HandleOfferReceivedAsync(
                peerDeviceId,
                clipboardPayload.GetProperty("sourceDeviceId").GetString() ?? string.Empty,
                clipboardPayload.GetProperty("offerId").GetString() ?? string.Empty,
                clipboardPayload.GetProperty("contentType").GetString() ?? string.Empty,
                clipboardPayload.GetProperty("byteSize").GetInt64(),
                clipboardPayload.GetProperty("sha256").GetString() ?? string.Empty,
                clipboardPayload.GetProperty("expiresInMs").GetInt64(),
                clipboardPayload.GetProperty("requiredCapability").GetString() ?? string.Empty,
                clipboardPayload.GetProperty("offerSequence").GetInt64());
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
}
