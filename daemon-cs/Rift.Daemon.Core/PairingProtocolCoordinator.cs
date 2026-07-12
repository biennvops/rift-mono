using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
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
    private static readonly TimeSpan ManualEndpointRetryDelay = TimeSpan.FromMilliseconds(400);

    private readonly ITransport _transport;
    private readonly IDiscoveryCoordinator _discoveryCoordinator;
    private readonly ITrustStore _trustStore;
    private readonly IIdentityManager _identityManager;
    private readonly ISecurityEventLog _securityEventLog;
    private readonly IIpcNotificationService? _ipcNotificationService;
    private readonly ILogger<PairingProtocolCoordinator> _logger;
    private readonly TimeProvider _timeProvider;
    private readonly ConcurrentDictionary<string, PairingSessionState> _pairingStates = new(StringComparer.Ordinal);
    private readonly ConcurrentDictionary<string, TrustedPeerEndpoint> _pendingTrustedEndpointHints = new(StringComparer.Ordinal);

    private static readonly Regex CanonicalDeviceIdRegex = new(@"^rift-[a-z2-7]{32}$", RegexOptions.Compiled);

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

        var connected = false;

        if (!_transport.HasActiveSession(deviceId) &&
            _discoveryCoordinator.TryGetDiscoveredPeer(deviceId, out var peer) &&
            peer is not null)
        {
            try
            {
                var connectedDeviceId = await ConnectToDiscoveredPeerAsync(deviceId, peer, cancellationToken);
                if (connectedDeviceId != deviceId)
                {
                    _logger.LogInformation("Mapped discovery instance ID {InstanceId} to authenticated device ID {DeviceId}.", deviceId, connectedDeviceId);
                    
                    // Migrate state to the real device ID
                    if (_pairingStates.TryRemove(deviceId, out var existingState))
                    {
                        _pairingStates[connectedDeviceId] = existingState;
                    }
                    deviceId = connectedDeviceId;
                }
                connected = true;
            }
            catch (Exception ex)
            {
                if (await WaitForActiveSessionAsync(deviceId, ActiveSessionFallbackWindow, cancellationToken))
                {
                    _logger.LogInformation(
                        "Recovered pairing start for peer {DeviceId} by reusing an authenticated session that arrived after outbound connect failed.",
                        deviceId);
                    connected = true;
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
                }
            }
        }

        if (!connected && !_transport.HasActiveSession(deviceId))
        {
            var trustRecord = _trustStore.GetPeer(deviceId);
            if (trustRecord is not null && trustRecord.TrustedEndpoints.Count > 0)
            {
                try
                {
                    var connectedDeviceId = await ConnectToTrustedEndpointsAsync(deviceId, trustRecord.TrustedEndpoints, cancellationToken);
                    if (connectedDeviceId != deviceId)
                    {
                        _logger.LogInformation("Mapped trusted endpoint device ID {OldDeviceId} to {NewDeviceId}.", deviceId, connectedDeviceId);
                        if (_pairingStates.TryRemove(deviceId, out var existingState))
                        {
                            _pairingStates[connectedDeviceId] = existingState;
                        }
                        deviceId = connectedDeviceId;
                    }
                    connected = true;
                }
                catch (Exception ex)
                {
                    if (await WaitForActiveSessionAsync(deviceId, ActiveSessionFallbackWindow, cancellationToken))
                    {
                        _logger.LogInformation(
                            "Recovered pairing start for peer {DeviceId} by reusing an authenticated session that arrived after trusted endpoint connect failed.",
                            deviceId);
                        connected = true;
                    }
                    else
                    {
                        _logger.LogWarning(ex, "Failed to establish outbound pairing session using trusted endpoints for {DeviceId}.", deviceId);
                    }
                }
            }
        }

        if (!connected && !_transport.HasActiveSession(deviceId))
        {
            throw new InvalidOperationException($"Failed to establish a secure session with {deviceId} for pairing. No discovered or persisted endpoints succeeded.");
        }

        try
        {
            _logger.LogInformation("Sending pairing.start to peer {DeviceId}.", deviceId);
            var platform = Environment.OSVersion.Platform == PlatformID.Win32NT ? "Windows" :
                           System.Runtime.InteropServices.RuntimeInformation.IsOSPlatform(System.Runtime.InteropServices.OSPlatform.OSX) ? "macOS" : "Linux";
            var idPart = new string(_identityManager.GetDeviceId().Split('-').LastOrDefault()?.Take(4).ToArray() ?? new char[] { '0', '0', '0', '0' }).ToUpperInvariant();
            var displayName = $"{platform} Desktop {idPart}";

            await SendProtocolMessageAsync(deviceId, "pairing.start", new
            {
                expiresInMs = PairingExpiryMs,
                displayName = displayName
            }, cancellationToken);
        }
        catch (InvalidOperationException ex) when (ex.Message.Contains("No open session exists", StringComparison.Ordinal))
        {
            throw new InvalidOperationException(
                $"Failed to start pairing with {deviceId} because no authenticated session is open.",
                ex);
        }
    }

    public async Task<string> ConnectToEndpointForPairingAsync(
        string host,
        int port,
        CancellationToken cancellationToken = default)
    {
        _logger.LogInformation(
            "Manual pairing endpoint requested for {Host}:{Port}.",
            host,
            port);

        try
        {
            var deviceId = await _transport.ConnectToPeerWithIdentityAsync(host, port, cancellationToken);
            _pendingTrustedEndpointHints[deviceId] = new TrustedPeerEndpoint
            {
                Address = host,
                Port = port,
                Source = "manual-pairing",
                AddressFamily = System.Net.IPAddress.TryParse(host, out var ipAddress)
                    ? ipAddress.AddressFamily.ToString()
                    : null,
                LastSuccessAt = _timeProvider.GetUtcNow()
            };
            return deviceId;
        }
        catch (Exception ex) when (IsLikelyDuplicateOutboundRace(ex))
        {
            if (ex.Data.Contains("DeviceId") && ex.Data["DeviceId"] is string deviceId)
            {
                _logger.LogInformation(
                    ex,
                    "Manual pairing endpoint {Host}:{Port} hit a duplicate bootstrap race for peer {DeviceId}. Waiting for the in-flight inbound session to become active.",
                    host,
                    port,
                    deviceId);

                if (IsCanonicalDeviceId(deviceId) && await WaitForActiveSessionAsync(deviceId, DuplicateOutboundRetryDelay, cancellationToken))
                {
                    _pendingTrustedEndpointHints[deviceId] = new TrustedPeerEndpoint
                    {
                        Address = host,
                        Port = port,
                        Source = "manual-pairing",
                        AddressFamily = System.Net.IPAddress.TryParse(host, out var ipAddress)
                            ? ipAddress.AddressFamily.ToString()
                            : null,
                        LastSuccessAt = _timeProvider.GetUtcNow()
                    };
                    return deviceId;
                }
            }

            _logger.LogInformation(
                ex,
                "Manual pairing endpoint {Host}:{Port} hit a duplicate bootstrap race. No inbound session became active. Retrying outbound connect once.",
                host,
                port);

            await Task.Delay(ManualEndpointRetryDelay, cancellationToken);
            var retriedDeviceId = await _transport.ConnectToPeerWithIdentityAsync(host, port, cancellationToken);
            _pendingTrustedEndpointHints[retriedDeviceId] = new TrustedPeerEndpoint
            {
                Address = host,
                Port = port,
                Source = "manual-pairing",
                AddressFamily = System.Net.IPAddress.TryParse(host, out var retryIpAddress)
                    ? retryIpAddress.AddressFamily.ToString()
                    : null,
                LastSuccessAt = _timeProvider.GetUtcNow()
            };
            return retriedDeviceId;
        }
    }

    private async Task<string> ConnectToDiscoveredPeerAsync(
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
                var connectedDeviceId = await ConnectToEndpointWithRetryAsync(deviceId, endpoint, cancellationToken);
                _pendingTrustedEndpointHints[connectedDeviceId] = new TrustedPeerEndpoint
                {
                    Address = endpoint.Address,
                    Port = endpoint.Port,
                    Source = "discovery-pairing",
                    AddressFamily = System.Net.IPAddress.TryParse(endpoint.Address, out var ipAddress)
                        ? ipAddress.AddressFamily.ToString()
                        : null,
                    LastSuccessAt = _timeProvider.GetUtcNow()
                };
                return connectedDeviceId;
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

    private async Task<string> ConnectToTrustedEndpointsAsync(
        string deviceId,
        IReadOnlyList<TrustedPeerEndpoint> endpoints,
        CancellationToken cancellationToken)
    {
        var failures = new List<(TrustedPeerEndpoint Endpoint, Exception Exception)>();

        foreach (var endpoint in endpoints)
        {
            try
            {
                return await ConnectToEndpointWithRetryAsync(deviceId, new DiscoveredPeerEndpoint { Address = endpoint.Address, Port = endpoint.Port }, cancellationToken);
            }
            catch (Exception ex)
            {
                failures.Add((endpoint, ex));
            }
        }

        var lastFailure = failures[^1];
        throw new InvalidOperationException(
            $"All persisted endpoints failed for {deviceId}. Last endpoint {lastFailure.Endpoint.Address}:{lastFailure.Endpoint.Port}. {DescribeConnectFailure(lastFailure.Exception)}",
            lastFailure.Exception);
    }

    private async Task<string> ConnectToEndpointWithRetryAsync(
        string deviceId,
        DiscoveredPeerEndpoint endpoint,
        CancellationToken cancellationToken)
    {
        try
        {
            return await _transport.ConnectToPeerWithIdentityAsync(endpoint.Address, endpoint.Port, cancellationToken);
        }
        catch (Exception ex) when (IsLikelyDuplicateOutboundRace(ex))
        {
            _logger.LogInformation(
                ex,
                "Peer {DeviceId} closed the duplicate outbound connection before session bootstrap completed on endpoint {Address}:{Port}. Waiting briefly for the in-flight inbound/prefetched session, then retrying once if needed.",
                deviceId,
                endpoint.Address,
                endpoint.Port);

            if (IsCanonicalDeviceId(deviceId) && 
                await WaitForActiveSessionAsync(deviceId, DuplicateOutboundRetryDelay, cancellationToken))
            {
                // We only return the deviceId if it's a verified authenticated device ID (matches canonical regex)
                // and we successfully found an active session for it. Temporary instance names fall through to retry.
                return deviceId;
            }

            return await _transport.ConnectToPeerWithIdentityAsync(endpoint.Address, endpoint.Port, cancellationToken);
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

        if (peer.State is TrustState.Discovered or TrustState.PairingPending &&
            peer.Ed25519PublicKey is not null)
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
            PersistTrustedEndpointIfAvailable(peerDeviceId, source: "pairing-session");
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

    private static bool IsCanonicalDeviceId(string deviceId)
    {
        return !string.IsNullOrEmpty(deviceId) && CanonicalDeviceIdRegex.IsMatch(deviceId);
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
            if (args.AllowsProtectedTraffic)
            {
                PersistTrustedEndpointIfAvailable(args.PeerDeviceId, source: "session-established");
            }
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

    private void PersistTrustedEndpointIfAvailable(string peerDeviceId, string source)
    {
        var peer = _trustStore.GetPeer(peerDeviceId);
        if (peer is null || peer.State != TrustState.Trusted)
        {
            return;
        }

        var endpoint = _transport.GetPeerSessionEndpoint(peerDeviceId);
        if (endpoint is null)
        {
            _logger.LogDebug(
                "No active session endpoint available to persist for trusted peer {DeviceId}.",
                peerDeviceId);
            return;
        }

        var persistedEndpoint = ResolveTrustedEndpointForPersistence(peerDeviceId, peer, endpoint, source);
        if (persistedEndpoint is null)
        {
            _logger.LogDebug(
                "Skipping trusted endpoint persistence for peer {DeviceId} because no stable listener port is known.",
                peerDeviceId);
            return;
        }

        peer.TrustedEndpoints = new[]
        {
            persistedEndpoint
        }
        .Concat(peer.TrustedEndpoints.Where(existing =>
            !string.Equals(existing.Address, persistedEndpoint.Address, StringComparison.Ordinal) ||
            existing.Port != persistedEndpoint.Port))
        .Take(4)
        .ToArray();

        _trustStore.SavePeer(peer);
        _logger.LogInformation(
            "Persisted trusted endpoint for peer {DeviceId} at {Address}:{Port} from {Source}.",
            peerDeviceId,
            endpoint.Address,
            endpoint.Port,
            source);
    }

    private TrustedPeerEndpoint? ResolveTrustedEndpointForPersistence(
        string peerDeviceId,
        PeerIdentity peer,
        PeerSessionEndpoint activeEndpoint,
        string source)
    {
        if (_pendingTrustedEndpointHints.TryRemove(peerDeviceId, out var hintedEndpoint))
        {
            return new TrustedPeerEndpoint
            {
                Address = hintedEndpoint.Address,
                Port = hintedEndpoint.Port,
                LastSuccessAt = _timeProvider.GetUtcNow(),
                AddressFamily = hintedEndpoint.AddressFamily,
                Source = source
            };
        }

        if (_discoveryCoordinator.TryGetDiscoveredPeer(peerDeviceId, out var discoveredPeer) &&
            discoveredPeer is not null)
        {
            var preferredEndpoint = discoveredPeer.ObservedEndpoints.Count > 0
                ? discoveredPeer.ObservedEndpoints[0]
                : new DiscoveredPeerEndpoint
                {
                    Address = discoveredPeer.Address,
                    Port = discoveredPeer.Port
                };

            return new TrustedPeerEndpoint
            {
                Address = preferredEndpoint.Address,
                Port = preferredEndpoint.Port,
                Source = source,
                AddressFamily = System.Net.IPAddress.TryParse(preferredEndpoint.Address, out var discoveredIpAddress)
                    ? discoveredIpAddress.AddressFamily.ToString()
                    : null,
                LastSuccessAt = _timeProvider.GetUtcNow()
            };
        }

        if (peer.TrustedEndpoints.Count > 0)
        {
            var existingEndpoint = peer.TrustedEndpoints[0];
            return new TrustedPeerEndpoint
            {
                Address = activeEndpoint.Address,
                Port = activeEndpoint.Port,
                Source = source,
                AddressFamily = System.Net.IPAddress.TryParse(activeEndpoint.Address, out var activeIpAddress)
                    ? activeIpAddress.AddressFamily.ToString()
                    : existingEndpoint.AddressFamily,
                LastSuccessAt = _timeProvider.GetUtcNow()
            };
        }

        return null;
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
