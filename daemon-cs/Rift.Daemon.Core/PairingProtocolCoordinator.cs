using System.Collections.Concurrent;
using System.Text;
using System.Text.Json;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;
using Rift.Daemon.Core.Interfaces;

namespace Rift.Daemon.Core;

public sealed class PairingProtocolCoordinator : IPairingProtocolCoordinator
{
    private const int PairingExpiryMs = 120000;

    private readonly ITransport _transport;
    private readonly IDiscoveryCoordinator _discoveryCoordinator;
    private readonly ITrustStore _trustStore;
    private readonly IIdentityManager _identityManager;
    private readonly ISecurityEventLog _securityEventLog;
    private readonly ILogger<PairingProtocolCoordinator> _logger;
    private readonly ConcurrentDictionary<string, PairingSessionState> _pairingStates = new(StringComparer.Ordinal);

    public PairingProtocolCoordinator(
        ITransport transport,
        IDiscoveryCoordinator discoveryCoordinator,
        ITrustStore trustStore,
        IIdentityManager identityManager,
        ISecurityEventLog securityEventLog,
        ILogger<PairingProtocolCoordinator>? logger = null)
    {
        _transport = transport;
        _discoveryCoordinator = discoveryCoordinator;
        _trustStore = trustStore;
        _identityManager = identityManager;
        _securityEventLog = securityEventLog;
        _logger = logger ?? NullLogger<PairingProtocolCoordinator>.Instance;
    }

    public void NotifyLocalPairingStarted(string deviceId)
    {
        var state = _pairingStates.GetOrAdd(deviceId, _ => new PairingSessionState());

        if (_discoveryCoordinator.TryGetDiscoveredPeer(deviceId, out var peer) && peer is not null)
        {
            try
            {
                _transport.ConnectToPeerAsync(peer.Address, peer.Port, CancellationToken.None).GetAwaiter().GetResult();
            }
            catch (Exception ex)
            {
                _logger.LogDebug(ex, "Ignoring outbound pairing connection failure for {DeviceId}.", deviceId);
            }
        }

        SendProtocolMessage(deviceId, "pairing.start", new
        {
            expiresInMs = PairingExpiryMs
        });
    }

    public void NotifyLocalPairingApproved(string deviceId)
    {
        var state = _pairingStates.GetOrAdd(deviceId, _ => new PairingSessionState());
        state.LocalApproved = true;

        var approvedAt = DateTimeOffset.UtcNow.ToString("O");
        SendProtocolMessage(deviceId, "pairing.approve", new
        {
            approvedAt
        });

        if (!state.CompletionSent)
        {
            state.CompletionSent = true;
            SendProtocolMessage(deviceId, "pairing.complete", new
            {
                trustedDeviceId = deviceId,
                persistedAt = approvedAt
            });
        }
    }

    public void NotifyLocalPairingRejected(string deviceId)
    {
        _pairingStates.TryRemove(deviceId, out _);
        SendProtocolMessage(deviceId, "pairing.reject", new
        {
            failureReason = "PeerRejected",
            message = "pairing rejected locally"
        });
    }

    public async Task HandleMessageAsync(string peerDeviceId, ReadOnlyMemory<byte> payload, CancellationToken cancellationToken)
    {
        using var document = JsonDocument.Parse(payload);
        var root = document.RootElement;
        var messageType = root.GetProperty("type").GetString();
        if (string.IsNullOrWhiteSpace(messageType) || !messageType.StartsWith("pairing.", StringComparison.Ordinal))
        {
            return;
        }

        var payloadElement = root.GetProperty("payload");
        switch (messageType)
        {
            case "pairing.start":
                HandlePairingStart(peerDeviceId);
                break;
            case "pairing.approve":
                _pairingStates.GetOrAdd(peerDeviceId, _ => new PairingSessionState()).RemoteApproved = true;
                break;
            case "pairing.reject":
                HandlePairingReject(peerDeviceId);
                break;
            case "pairing.complete":
                await HandlePairingCompleteAsync(peerDeviceId, payloadElement, cancellationToken);
                break;
        }
    }

    private void HandlePairingStart(string peerDeviceId)
    {
        var peer = _trustStore.GetPeer(peerDeviceId);
        if (peer is null)
        {
            return;
        }

        if (peer.State == TrustState.Discovered)
        {
            _trustStore.TryTransition(peerDeviceId, TrustState.PairingPending);
        }

        _pairingStates.GetOrAdd(peerDeviceId, _ => new PairingSessionState());
        LogEvent(SecurityEventTypes.PairingAttempted, peerDeviceId, SecurityEventOutcome.Success, null);
    }

    private void HandlePairingReject(string peerDeviceId)
    {
        _pairingStates.TryRemove(peerDeviceId, out _);
        _trustStore.TryTransition(peerDeviceId, TrustState.Discovered);
        LogEvent(SecurityEventTypes.PairingRejected, peerDeviceId, SecurityEventOutcome.Failure, "PeerRejected");
    }

    private async Task HandlePairingCompleteAsync(string peerDeviceId, JsonElement payload, CancellationToken cancellationToken)
    {
        var trustedDeviceId = payload.GetProperty("trustedDeviceId").GetString();
        if (!string.Equals(trustedDeviceId, peerDeviceId, StringComparison.Ordinal))
        {
            await _securityEventLog.LogEventAsync(new SecurityEventRecord
            {
                EventType = SecurityEventTypes.AuthFailed,
                Severity = SecurityEventSeverity.Critical,
                LocalDeviceId = _identityManager.GetDeviceId(),
                PeerDeviceId = peerDeviceId,
                Outcome = SecurityEventOutcome.Failure,
                FailureReason = "AuthenticationFailed"
            });
            return;
        }

        var state = _pairingStates.GetOrAdd(peerDeviceId, _ => new PairingSessionState());
        state.RemoteCompleted = true;

        var peer = _trustStore.GetPeer(peerDeviceId);
        if (peer is null)
        {
            return;
        }

        if (peer.State == TrustState.Trusted)
        {
            return;
        }

        if (peer.State == TrustState.PairingPending && state.LocalApproved)
        {
            _trustStore.TryTransition(peerDeviceId, TrustState.Trusted);
            LogEvent(SecurityEventTypes.PairingCompleted, peerDeviceId, SecurityEventOutcome.Success, null);
        }

        await Task.CompletedTask;
    }

    private void SendProtocolMessage(string peerDeviceId, string messageType, object payload)
    {
        var envelope = new
        {
            rift = "0.1-draft",
            type = messageType,
            messageId = Guid.NewGuid().ToString("D"),
            sourceDeviceId = _identityManager.GetDeviceId(),
            payload
        };

        var bytes = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(envelope));
        _transport.SendAsync(peerDeviceId, bytes, CancellationToken.None).GetAwaiter().GetResult();
    }

    private void LogEvent(string eventType, string deviceId, SecurityEventOutcome outcome, string? failureReason)
    {
        _securityEventLog.LogEventAsync(new SecurityEventRecord
        {
            EventType = eventType,
            Severity = outcome == SecurityEventOutcome.Success ? SecurityEventSeverity.Info : SecurityEventSeverity.Warning,
            LocalDeviceId = _identityManager.GetDeviceId(),
            PeerDeviceId = deviceId,
            Outcome = outcome,
            FailureReason = failureReason
        }).GetAwaiter().GetResult();
    }

    private sealed class PairingSessionState
    {
        public bool LocalApproved { get; set; }

        public bool RemoteApproved { get; set; }

        public bool RemoteCompleted { get; set; }

        public bool CompletionSent { get; set; }
    }
}
