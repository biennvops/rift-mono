using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Text;
using System.Text.Json;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;
using Rift.Daemon.Core.Cryptography;
using Rift.Daemon.Core.Interfaces;

namespace Rift.Daemon.Core;

public sealed class PairingProtocolCoordinator : IPairingProtocolCoordinator
    , IDisposable
{
    private const int PairingExpiryMs = 120000;
    // Android's Dart SecureServerSocket cannot provisionally accept arbitrary
    // self-signed client certificates on inbound TLS, so when pairing against
    // Android we prefer to wait longer for a peer-initiated authenticated
    // session to appear before attempting our own outbound connect.
    private static readonly TimeSpan InitialSessionReuseWindow = TimeSpan.FromSeconds(2);
    private static readonly TimeSpan ActiveSessionFallbackWindow = TimeSpan.FromSeconds(4);
    private static readonly TimeSpan DuplicateOutboundRetryDelay = TimeSpan.FromMilliseconds(1250);

    private readonly ITransport _transport;
    private readonly IDiscoveryCoordinator _discoveryCoordinator;
    private readonly ITrustStore _trustStore;
    private readonly IIdentityManager _identityManager;
    private readonly ISecurityEventLog _securityEventLog;
    private readonly IIpcNotificationService? _ipcNotificationService;
    private readonly ILogger<PairingProtocolCoordinator> _logger;
    private readonly TimeProvider _timeProvider;
    private readonly ConcurrentDictionary<string, PairingSessionState> _pairingStates = new(StringComparer.Ordinal);

    public PairingProtocolCoordinator(
        ITransport transport,
        IDiscoveryCoordinator discoveryCoordinator,
        ITrustStore trustStore,
        IIdentityManager identityManager,
        ISecurityEventLog securityEventLog,
        IIpcNotificationService? ipcNotificationService = null,
        ILogger<PairingProtocolCoordinator>? logger = null,
        TimeProvider? timeProvider = null)
    {
        _transport = transport;
        _discoveryCoordinator = discoveryCoordinator;
        _trustStore = trustStore;
        _identityManager = identityManager;
        _securityEventLog = securityEventLog;
        _ipcNotificationService = ipcNotificationService;
        _logger = logger ?? NullLogger<PairingProtocolCoordinator>.Instance;
        _timeProvider = timeProvider ?? TimeProvider.System;
        _transport.SessionStateChanged += OnSessionStateChanged;
    }

    public void Dispose()
    {
        // The coordinator is typically a singleton in the current DI setup, but unsubscribing is
        // still the correct lifecycle behavior and prevents accidental leaks in tests or future
        // hosting configurations.
        _transport.SessionStateChanged -= OnSessionStateChanged;
    }

    public async Task NotifyLocalPairingStartedAsync(string deviceId, CancellationToken cancellationToken = default)
    {
        _logger.LogInformation("Pairing start requested locally for peer {DeviceId}.", deviceId);
        await PruneExpiredSessionsAsync(cancellationToken);
        var state = _pairingStates.AddOrUpdate(
            deviceId,
            _ => CreatePairingSessionState(),
            (_, existing) => existing.Refresh(_timeProvider.GetUtcNow().AddMilliseconds(PairingExpiryMs)));
        state.MarkLocalApproved();

        if (!_transport.HasActiveSession(deviceId) &&
            await WaitForActiveSessionAsync(deviceId, InitialSessionReuseWindow, cancellationToken))
        {
            _logger.LogInformation(
                "Pairing start for peer {DeviceId} is reusing an authenticated session that became available before outbound connect.",
                deviceId);
        }

        if (!_transport.HasActiveSession(deviceId) &&
            _discoveryCoordinator.TryGetDiscoveredPeer(deviceId, out var peer) &&
            peer is not null)
        {
            try
            {
                await ConnectToDiscoveredPeerAsync(deviceId, peer, cancellationToken);
            }
            catch (Exception ex)
            {
                if (await WaitForActiveSessionAsync(deviceId, ActiveSessionFallbackWindow, cancellationToken))
                {
                    _logger.LogInformation(
                        "Recovered pairing start for peer {DeviceId} by reusing an authenticated session that arrived after outbound connect failed.",
                        deviceId);
                }
                else
                {
                    _logger.LogWarning(
                        ex,
                        "Failed to establish outbound pairing session for {DeviceId} using {Address}:{Port}. Classification={Classification}",
                        deviceId,
                        peer.Address,
                        peer.Port,
                        ClassifyConnectFailure(ex));
                    throw new InvalidOperationException(
                        $"Failed to establish a secure session with {deviceId} at {peer.Address}:{peer.Port}. {DescribeConnectFailure(ex)}",
                        ex);
                }
            }
        }

        try
        {
            _logger.LogInformation("Sending pairing.start to peer {DeviceId}.", deviceId);
            await SendProtocolMessageAsync(deviceId, "pairing.start", new
            {
                expiresInMs = PairingExpiryMs
            }, cancellationToken);
        }
        catch (InvalidOperationException ex) when (ex.Message.Contains("No open session exists", StringComparison.Ordinal))
        {
            throw new InvalidOperationException(
                $"Failed to start pairing with {deviceId} because no authenticated session is open.",
                ex);
        }
    }

    private async Task ConnectToDiscoveredPeerAsync(
        string deviceId,
        DiscoveredPeerInfo peer,
        CancellationToken cancellationToken)
    {
        var endpoints = peer.ObservedEndpoints.Count > 0
            ? peer.ObservedEndpoints
            : [new DiscoveredPeerEndpoint { Address = peer.Address, Port = peer.Port }];
        var failures = new List<(DiscoveredPeerEndpoint Endpoint, Exception Exception)>();

        foreach (var endpoint in endpoints)
        {
            try
            {
                await ConnectToEndpointWithRetryAsync(deviceId, endpoint, cancellationToken);
                return;
            }
            catch (Exception ex)
            {
                failures.Add((endpoint, ex));
                _logger.LogInformation(
                    ex,
                    "Outbound pairing connect attempt for {DeviceId} via {Address}:{Port} failed. Classification={Classification}",
                    deviceId,
                    endpoint.Address,
                    endpoint.Port,
                    ClassifyConnectFailure(ex));
            }
        }

        var lastFailure = failures[^1];
        throw new InvalidOperationException(
            $"All discovered endpoints failed for {deviceId}. Last endpoint {lastFailure.Endpoint.Address}:{lastFailure.Endpoint.Port}. {DescribeConnectFailure(lastFailure.Exception)}",
            lastFailure.Exception);
    }

    private async Task ConnectToEndpointWithRetryAsync(
        string deviceId,
        DiscoveredPeerEndpoint endpoint,
        CancellationToken cancellationToken)
    {
        try
        {
            await _transport.ConnectToPeerAsync(endpoint.Address, endpoint.Port, cancellationToken);
        }
        catch (Exception ex) when (IsLikelyDuplicateOutboundRace(ex))
        {
            _logger.LogInformation(
                ex,
                "Peer {DeviceId} closed the duplicate outbound connection before session bootstrap completed on endpoint {Address}:{Port}. Waiting briefly for the in-flight inbound/prefetched session, then retrying once if needed.",
                deviceId,
                endpoint.Address,
                endpoint.Port);

            if (await WaitForActiveSessionAsync(deviceId, DuplicateOutboundRetryDelay, cancellationToken))
            {
                return;
            }

            await _transport.ConnectToPeerAsync(endpoint.Address, endpoint.Port, cancellationToken);
        }
    }

    public async Task NotifyLocalPairingApprovedAsync(string deviceId, CancellationToken cancellationToken = default)
    {
        _logger.LogInformation("Pairing approve requested locally for peer {DeviceId}.", deviceId);
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
        _logger.LogInformation("Sent pairing.approve to peer {DeviceId}.", deviceId);

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
        _logger.LogInformation("Received pairing protocol message {MessageType} from peer {DeviceId}.", messageType, peerDeviceId);
        switch (messageType)
        {
            case "pairing.start":
                await HandlePairingStartAsync(peerDeviceId, payloadElement, cancellationToken);
                break;
            case "pairing.approve":
                await HandlePairingApproveAsync(peerDeviceId, cancellationToken);
                break;
            case "pairing.reject":
                await HandlePairingRejectAsync(peerDeviceId);
                break;
            case "pairing.complete":
                await HandlePairingCompleteAsync(peerDeviceId, payloadElement, cancellationToken);
                break;
        }
    }

    private async Task HandlePairingStartAsync(string peerDeviceId, JsonElement payload, CancellationToken cancellationToken)
    {
        var peer = _trustStore.GetPeer(peerDeviceId);
        if (peer is null)
        {
            return;
        }

        var previousState = peer.State;
        if (peer.State == TrustState.Discovered)
        {
            _trustStore.TryTransition(peerDeviceId, TrustState.PairingPending);
            await NotifyTrustChangedAsync(peerDeviceId, "discovered", "pairing_pending", "Remote pairing started.", cancellationToken);
        }

        _pairingStates.AddOrUpdate(
            peerDeviceId,
            _ =>
            {
                var created = CreatePairingSessionState();
                created.MarkRemoteApproved();
                return created;
            },
            (_, existing) =>
            {
                existing.Refresh(_timeProvider.GetUtcNow().AddMilliseconds(PairingExpiryMs));
                existing.MarkRemoteApproved();
                return existing;
            });
        await LogEventAsync(SecurityEventTypes.PairingAttempted, peerDeviceId, SecurityEventOutcome.Success, null, cancellationToken);

        if (previousState == TrustState.Discovered && peer.Ed25519PublicKey is not null)
        {
            var expiresInMs = payload.TryGetProperty("expiresInMs", out var expiresElement) && expiresElement.ValueKind == JsonValueKind.Number
                ? expiresElement.GetInt32()
                : PairingExpiryMs;
            expiresInMs = expiresInMs <= 0 ? PairingExpiryMs : Math.Clamp(expiresInMs, 1000, PairingExpiryMs);
            var displayName = payload.TryGetProperty("displayName", out var displayNameElement) && displayNameElement.ValueKind == JsonValueKind.String
                ? displayNameElement.GetString()
                : null;

            await NotifyPairingRequestAsync(
                peerDeviceId,
                IdentityManager.DeriveFingerprint(peer.Ed25519PublicKey),
                displayName ?? peerDeviceId,
                expiresInMs,
                cancellationToken);
        }
    }

    private async Task HandlePairingApproveAsync(string peerDeviceId, CancellationToken cancellationToken)
    {
        var peer = _trustStore.GetPeer(peerDeviceId);
        if (peer is null)
        {
            return;
        }

        var state = _pairingStates.AddOrUpdate(
            peerDeviceId,
            _ => CreatePairingSessionState(),
            (_, existing) => existing.Refresh(_timeProvider.GetUtcNow().AddMilliseconds(PairingExpiryMs)));
        state.MarkRemoteApproved();
        await TrySendPairingCompleteAsync(peerDeviceId, state, _timeProvider.GetUtcNow().ToString("O"), cancellationToken);
    }

    private async Task HandlePairingRejectAsync(string peerDeviceId)
    {
        _pairingStates.TryRemove(peerDeviceId, out _);
        _trustStore.TryTransition(peerDeviceId, TrustState.Discovered);
        await LogEventAsync(SecurityEventTypes.PairingRejected, peerDeviceId, SecurityEventOutcome.Failure, "PeerRejected", CancellationToken.None);
        await NotifyTrustChangedAsync(peerDeviceId, "pairing_pending", "discovered", "Peer rejected pairing.", CancellationToken.None);
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
            await NotifyTrustChangedAsync(peerDeviceId, "pairing_pending", "trusted", "Pairing completed.", cancellationToken);
            if (peer.Ed25519PublicKey is not null)
            {
                var persistedAt = payload.GetProperty("persistedAt").GetString() ?? _timeProvider.GetUtcNow().ToString("O");
                await NotifyPairingCompleteAsync(
                    peerDeviceId,
                    IdentityManager.DeriveFingerprint(peer.Ed25519PublicKey),
                    persistedAt,
                    cancellationToken);
            }
        }
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

    private static bool IsLikelyDuplicateOutboundRace(Exception ex)
    {
        return ex is InvalidOperationException invalidOperationException &&
               invalidOperationException.Message.Contains(
                   "Peer closed connection before sending session.hello.",
                   StringComparison.Ordinal);
    }

    private static string ClassifyConnectFailure(Exception ex)
    {
        if (IsLikelyDuplicateOutboundRace(ex))
        {
            return "peer-closed-before-hello";
        }

        if (ex is System.Net.Sockets.SocketException socketException)
        {
            return socketException.SocketErrorCode switch
            {
                System.Net.Sockets.SocketError.ConnectionRefused => "connection-refused",
                System.Net.Sockets.SocketError.InvalidArgument => "invalid-endpoint-argument",
                System.Net.Sockets.SocketError.HostNotFound => "host-not-found",
                System.Net.Sockets.SocketError.HostUnreachable => "host-unreachable",
                System.Net.Sockets.SocketError.NetworkUnreachable => "network-unreachable",
                _ => $"socket-{socketException.SocketErrorCode.ToString().ToLowerInvariant()}"
            };
        }

        return ex.GetType().Name;
    }

    private static string DescribeConnectFailure(Exception ex)
    {
        if (IsLikelyDuplicateOutboundRace(ex))
        {
            return "The peer accepted TCP/TLS but closed the bootstrap connection before replying. This commonly means a duplicate-session race or that the peer rejected session bootstrap.";
        }

        if (ex is System.Net.Sockets.SocketException socketException)
        {
            return socketException.SocketErrorCode switch
            {
                System.Net.Sockets.SocketError.ConnectionRefused =>
                    "The advertised peer endpoint refused the TCP connection. The discovery record may be stale, or the peer may no longer be listening on that port.",
                System.Net.Sockets.SocketError.InvalidArgument =>
                    "The selected endpoint was not usable for connect(). This commonly happens with an IPv6 link-local address that is missing a scope ID or another invalid local-network endpoint.",
                System.Net.Sockets.SocketError.HostNotFound =>
                    "The advertised hostname could not be resolved on the local network.",
                System.Net.Sockets.SocketError.HostUnreachable =>
                    "The peer host was discovered but not reachable on the local network.",
                System.Net.Sockets.SocketError.NetworkUnreachable =>
                    "No local network route was available to the discovered peer endpoint.",
                _ =>
                    $"Socket error: {socketException.SocketErrorCode}."
            };
        }

        return $"Underlying error: {ex.Message}";
    }

    private async Task<bool> WaitForActiveSessionAsync(string peerDeviceId, TimeSpan timeout, CancellationToken cancellationToken)
    {
        if (_transport.HasActiveSession(peerDeviceId))
        {
            return true;
        }

        var tcs = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);

        void Handler(object? _, SessionStateChangedEventArgs args)
        {
            if (args.IsOnline && string.Equals(args.PeerDeviceId, peerDeviceId, StringComparison.Ordinal))
            {
                tcs.TrySetResult(true);
            }
        }

        _transport.SessionStateChanged += Handler;
        try
        {
            if (_transport.HasActiveSession(peerDeviceId))
            {
                return true;
            }

            using var timeoutCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            timeoutCts.CancelAfter(timeout);

            using var registration = timeoutCts.Token.Register(
                static state => ((TaskCompletionSource<bool>)state!).TrySetResult(false),
                tcs);

            return await tcs.Task.ConfigureAwait(false);
        }
        finally
        {
            _transport.SessionStateChanged -= Handler;
        }
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
            trustedDeviceId = _identityManager.GetDeviceId(),
            persistedAt
        }, cancellationToken);
    }

    private void OnSessionStateChanged(object? sender, SessionStateChangedEventArgs args)
    {
        if (args.IsOnline)
        {
            return;
        }

        _ = Task.Run(async () =>
        {
            try
            {
                await HandlePeerDisconnectedAsync(args.PeerDeviceId).ConfigureAwait(false);
            }
            catch (Exception ex)
            {
                _logger.LogWarning(ex, "Failed to clean up pairing state after peer {DeviceId} disconnected.", args.PeerDeviceId);
            }
        });
    }

    private async Task HandlePeerDisconnectedAsync(string peerDeviceId)
    {
        _pairingStates.TryRemove(peerDeviceId, out _);

        var peer = _trustStore.GetPeer(peerDeviceId);
        if (peer is null || peer.State != TrustState.PairingPending)
        {
            return;
        }

        if (!_trustStore.TryTransition(peerDeviceId, TrustState.Discovered))
        {
            return;
        }

        await LogEventAsync(
            SecurityEventTypes.PairingRejected,
            peerDeviceId,
            SecurityEventOutcome.Failure,
            "PeerUnreachable",
            CancellationToken.None).ConfigureAwait(false);
        await NotifyTrustChangedAsync(peerDeviceId, "pairing_pending", "discovered", "Peer became unreachable during pairing.", CancellationToken.None).ConfigureAwait(false);
    }

    private Task NotifyTrustChangedAsync(string deviceId, string previousState, string newState, string reason, CancellationToken cancellationToken)
    {
        if (_ipcNotificationService is null)
        {
            return Task.CompletedTask;
        }

        return _ipcNotificationService.NotifyAsync("rift.onTrustChanged", new
        {
            deviceId,
            previousState,
            newState,
            reason
        }, cancellationToken);
    }

    private Task NotifyPairingRequestAsync(string deviceId, string fingerprint, string displayName, int expiresInMs, CancellationToken cancellationToken)
    {
        if (_ipcNotificationService is null)
        {
            return Task.CompletedTask;
        }

        return _ipcNotificationService.NotifyAsync("rift.onPairingRequest", new
        {
            deviceId,
            fingerprint,
            displayName,
            expiresInMs
        }, cancellationToken);
    }

    private Task NotifyPairingCompleteAsync(string deviceId, string fingerprint, string persistedAt, CancellationToken cancellationToken)
    {
        if (_ipcNotificationService is null)
        {
            return Task.CompletedTask;
        }

        return _ipcNotificationService.NotifyAsync("rift.onPairingComplete", new
        {
            deviceId,
            fingerprint,
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
