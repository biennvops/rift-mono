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
    private readonly TimeProvider _timeProvider;
    private readonly ConcurrentDictionary<string, PairingSessionState> _pairingStates = new(StringComparer.Ordinal);

    public PairingProtocolCoordinator(
        ITransport transport,
        IDiscoveryCoordinator discoveryCoordinator,
        ITrustStore trustStore,
        IIdentityManager identityManager,
        ISecurityEventLog securityEventLog,
        ILogger<PairingProtocolCoordinator>? logger = null,
        TimeProvider? timeProvider = null)
    {
        _transport = transport;
        _discoveryCoordinator = discoveryCoordinator;
        _trustStore = trustStore;
        _identityManager = identityManager;
        _securityEventLog = securityEventLog;
        _logger = logger ?? NullLogger<PairingProtocolCoordinator>.Instance;
        _timeProvider = timeProvider ?? TimeProvider.System;
    }

    public async Task NotifyLocalPairingStartedAsync(string deviceId, CancellationToken cancellationToken = default)
    {
        await PruneExpiredSessionsAsync(cancellationToken);
        _pairingStates.AddOrUpdate(
            deviceId,
            _ => CreatePairingSessionState(),
            (_, existing) => existing.Refresh(_timeProvider.GetUtcNow().AddMilliseconds(PairingExpiryMs)));

        if (_discoveryCoordinator.TryGetDiscoveredPeer(deviceId, out var peer) && peer is not null)
        {
            try
            {
                await _transport.ConnectToPeerAsync(peer.Address, peer.Port, cancellationToken);
            }
            catch (Exception ex)
            {
                _logger.LogDebug(ex, "Ignoring outbound pairing connection failure for {DeviceId}.", deviceId);
            }
        }

        await SendProtocolMessageAsync(deviceId, "pairing.start", new
        {
            expiresInMs = PairingExpiryMs
        }, cancellationToken);
    }

    public async Task NotifyLocalPairingApprovedAsync(string deviceId, CancellationToken cancellationToken = default)
    {
        await PruneExpiredSessionsAsync(cancellationToken);
        var state = _pairingStates.AddOrUpdate(
            deviceId,
            _ => CreatePairingSessionState(),
            (_, existing) => existing.Refresh(_timeProvider.GetUtcNow().AddMilliseconds(PairingExpiryMs)));
        state.MarkLocalApproved();

        var approvedAt = _timeProvider.GetUtcNow().ToString("O");
        await SendProtocolMessageAsync(deviceId, "pairing.approve", new
        {
            approvedAt
        }, cancellationToken);

        await TrySendPairingCompleteAsync(deviceId, state, approvedAt, cancellationToken);
    }

    public Task NotifyLocalPairingRejectedAsync(string deviceId, CancellationToken cancellationToken = default)
    {
        _pairingStates.TryRemove(deviceId, out _);
        return SendProtocolMessageAsync(deviceId, "pairing.reject", new
        {
            failureReason = "PeerRejected",
            message = "pairing rejected locally"
        }, cancellationToken);
    }

    public async Task HandleMessageAsync(string peerDeviceId, ReadOnlyMemory<byte> payload, CancellationToken cancellationToken)
    {
        await PruneExpiredSessionsAsync(cancellationToken);
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
                await HandlePairingStartAsync(peerDeviceId, cancellationToken);
                break;
            case "pairing.approve":
                var state = _pairingStates.AddOrUpdate(
                    peerDeviceId,
                    _ => CreatePairingSessionState(),
                    (_, existing) => existing.Refresh(_timeProvider.GetUtcNow().AddMilliseconds(PairingExpiryMs)));
                state.MarkRemoteApproved();
                await TrySendPairingCompleteAsync(peerDeviceId, state, _timeProvider.GetUtcNow().ToString("O"), cancellationToken);
                break;
            case "pairing.reject":
                await HandlePairingRejectAsync(peerDeviceId);
                break;
            case "pairing.complete":
                await HandlePairingCompleteAsync(peerDeviceId, payloadElement, cancellationToken);
                break;
        }
    }

    private async Task HandlePairingStartAsync(string peerDeviceId, CancellationToken cancellationToken)
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

        _pairingStates.AddOrUpdate(
            peerDeviceId,
            _ => CreatePairingSessionState(),
            (_, existing) => existing.Refresh(_timeProvider.GetUtcNow().AddMilliseconds(PairingExpiryMs)));
        await LogEventAsync(SecurityEventTypes.PairingAttempted, peerDeviceId, SecurityEventOutcome.Success, null, cancellationToken);
    }

    private async Task HandlePairingRejectAsync(string peerDeviceId)
    {
        _pairingStates.TryRemove(peerDeviceId, out _);
        _trustStore.TryTransition(peerDeviceId, TrustState.Discovered);
        await LogEventAsync(SecurityEventTypes.PairingRejected, peerDeviceId, SecurityEventOutcome.Failure, "PeerRejected", CancellationToken.None);
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

        var peer = _trustStore.GetPeer(peerDeviceId);
        if (peer is null)
        {
            return;
        }

        if (!_pairingStates.TryGetValue(peerDeviceId, out var state))
        {
            return;
        }

        state.Refresh(_timeProvider.GetUtcNow().AddMilliseconds(PairingExpiryMs));

        if (peer.State == TrustState.Trusted)
        {
            return;
        }

        if (peer.State == TrustState.PairingPending && state.HasMutualApproval())
        {
            _trustStore.TryTransition(peerDeviceId, TrustState.Trusted);
            await LogEventAsync(SecurityEventTypes.PairingCompleted, peerDeviceId, SecurityEventOutcome.Success, null, cancellationToken);
        }

        await Task.CompletedTask;
    }

    private async Task PruneExpiredSessionsAsync(CancellationToken cancellationToken)
    {
        var now = _timeProvider.GetUtcNow();
        foreach (var entry in _pairingStates)
        {
            if (entry.Value.ExpiresAt > now)
            {
                continue;
            }

            if (!_pairingStates.TryRemove(entry.Key, out _))
            {
                continue;
            }

            var peer = _trustStore.GetPeer(entry.Key);
            if (peer is not null && peer.State == TrustState.PairingPending)
            {
                _trustStore.TryTransition(entry.Key, TrustState.Discovered);
            }

            await LogEventAsync(SecurityEventTypes.PairingRejected, entry.Key, SecurityEventOutcome.Failure, "Timeout", cancellationToken);
        }
    }

    private PairingSessionState CreatePairingSessionState()
    {
        return new PairingSessionState(_timeProvider.GetUtcNow().AddMilliseconds(PairingExpiryMs));
    }

    private async Task SendProtocolMessageAsync(string peerDeviceId, string messageType, object payload, CancellationToken cancellationToken)
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
        await _transport.SendAsync(peerDeviceId, bytes, cancellationToken);
    }

    private async Task TrySendPairingCompleteAsync(string deviceId, PairingSessionState state, string persistedAt, CancellationToken cancellationToken)
    {
        if (!state.TryMarkCompletionSent())
        {
            return;
        }

        await SendProtocolMessageAsync(deviceId, "pairing.complete", new
        {
            trustedDeviceId = deviceId,
            persistedAt
        }, cancellationToken);
    }

    private Task LogEventAsync(string eventType, string deviceId, SecurityEventOutcome outcome, string? failureReason, CancellationToken cancellationToken)
    {
        return _securityEventLog.LogEventAsync(new SecurityEventRecord
        {
            EventType = eventType,
            Severity = outcome == SecurityEventOutcome.Success ? SecurityEventSeverity.Info : SecurityEventSeverity.Warning,
            LocalDeviceId = _identityManager.GetDeviceId(),
            PeerDeviceId = deviceId,
            Outcome = outcome,
            FailureReason = failureReason
        });
    }

    private sealed class PairingSessionState
    {
        private readonly object _syncRoot = new();
        private bool _localApproved;
        private bool _remoteApproved;
        private bool _completionSent;

        public PairingSessionState(DateTimeOffset expiresAt)
        {
            ExpiresAt = expiresAt;
        }

        public DateTimeOffset ExpiresAt { get; private set; }

        public PairingSessionState Refresh(DateTimeOffset expiresAt)
        {
            lock (_syncRoot)
            {
                ExpiresAt = expiresAt;
            }

            return this;
        }

        public void MarkLocalApproved()
        {
            lock (_syncRoot)
            {
                _localApproved = true;
            }
        }

        public void MarkRemoteApproved()
        {
            lock (_syncRoot)
            {
                _remoteApproved = true;
            }
        }

        public bool HasMutualApproval()
        {
            lock (_syncRoot)
            {
                return _localApproved && _remoteApproved;
            }
        }

        public bool TryMarkCompletionSent()
        {
            lock (_syncRoot)
            {
                if (!_localApproved || !_remoteApproved || _completionSent)
                {
                    return false;
                }

                _completionSent = true;
                return true;
            }
        }
    }
}
