using System;
using System.Collections.Concurrent;
using System.IO;
using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Security.Cryptography.X509Certificates;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;
using Rift.Daemon.Core.Interfaces;
using Rift.Daemon.Core.Protocol;
using Rift.Daemon.Core.Cryptography;
using Org.BouncyCastle.Asn1;
using BouncyCertificateParser = Org.BouncyCastle.X509.X509CertificateParser;

namespace Rift.Daemon.Core.Networking;

public sealed class TlsTransport : ITransport, IDisposable
{
    internal static readonly TimeSpan CapabilityNegotiationTimeout = TimeSpan.FromSeconds(10);

    private readonly ILogger<TlsTransport> _logger;
    private readonly IIdentityManager _identityManager;
    private readonly ITrustStore? _trustStore;
    private readonly ISecurityEventLog? _securityEventLog;
    private readonly SessionBootstrap _sessionBootstrap;
    private readonly SessionCapabilityCoordinator _sessionCapabilityCoordinator = new();
    private readonly CancellationTokenSource _shutdownCts = new();
    private TcpListener? _listener;
    private readonly ConcurrentDictionary<string, ActiveSession> _sessions = new();
    private readonly ConcurrentDictionary<int, Task> _backgroundTasks = new();
    private int _nextBackgroundTaskId;
    
    public event EventHandler<MessageReceivedEventArgs>? MessageReceived;
    public event EventHandler<SessionStateChangedEventArgs>? SessionStateChanged;

    public TlsTransport(
        ILogger<TlsTransport> logger,
        IIdentityManager identityManager,
        ITrustStore? trustStore = null,
        ISecurityEventLog? securityEventLog = null)
    {
        _logger = logger;
        _identityManager = identityManager;
        _trustStore = trustStore;
        _securityEventLog = securityEventLog;
        _sessionBootstrap = new SessionBootstrap(NullLogger<SessionBootstrap>.Instance, identityManager);
    }

    public async Task StartListeningAsync(CancellationToken cancellationToken)
    {
        using var linkedCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, _shutdownCts.Token);
        var linkedToken = linkedCts.Token;

        _listener = new TcpListener(IPAddress.Any, RiftNetworkDefaults.DefaultPort);
        _listener.Start();
        _logger.LogInformation("TlsTransport listening on port {Port}.", RiftNetworkDefaults.DefaultPort);

        try
        {
            while (!linkedToken.IsCancellationRequested)
            {
                var client = await _listener.AcceptTcpClientAsync(linkedToken);
                TrackBackgroundTask(HandleInboundConnectionAsync(client, linkedToken), "inbound connection");
            }
        }
        catch (OperationCanceledException)
        {
            // Normal shutdown
        }
        finally
        {
            _listener.Stop();
        }
    }

    private async Task HandleInboundConnectionAsync(TcpClient client, CancellationToken cancellationToken)
    {
        var remoteEndPoint = client.Client.RemoteEndPoint;
        try
        {
            var stream = client.GetStream();
            var sslStream = new SslStream(stream, false, RemoteCertificateValidationCallback);
            
            var serverCert = _identityManager.GetTlsCertificate();
            
            // Spec §5.1: Mutual TLS with TLS 1.3 preferred.
            await sslStream.AuthenticateAsServerAsync(new SslServerAuthenticationOptions
            {
                ServerCertificate = serverCert,
                ClientCertificateRequired = true,
                EnabledSslProtocols = SslProtocols.Tls13 | SslProtocols.Tls12,
                CertificateRevocationCheckMode = X509RevocationMode.NoCheck // Peer certs are self-signed
            }, cancellationToken);

            await SessionLoopAsync(sslStream, client, cancellationToken);
        }
        catch (IOException ex) when (!cancellationToken.IsCancellationRequested &&
                                     ex.Message.Contains("unexpected EOF", StringComparison.OrdinalIgnoreCase))
        {
            _logger.LogInformation(
                ex,
                "Peer closed inbound TLS handshake early from {RemoteEndPoint}. This commonly means the client rejected our certificate before mTLS completed.",
                remoteEndPoint);
            client.Close();
        }
        catch (AuthenticationException ex) when (!cancellationToken.IsCancellationRequested)
        {
            _logger.LogWarning(
                ex,
                "Inbound TLS authentication failed for {RemoteEndPoint}.",
                remoteEndPoint);
            client.Close();
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to authenticate inbound TLS connection from {RemoteEndPoint}.", remoteEndPoint);
            client.Close();
        }
    }

    public Task ConnectToPeerAsync(string host, int port, CancellationToken cancellationToken) =>
        ConnectToPeerWithIdentityAsync(host, port, cancellationToken);

    public async Task<string> ConnectToPeerWithIdentityAsync(string host, int port, CancellationToken cancellationToken)
    {
        using var linkedCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, _shutdownCts.Token);
        var linkedToken = linkedCts.Token;
        var client = new TcpClient();
        SslStream? sslStream = null;

        try
        {
            await client.ConnectAsync(host, port, linkedToken);

            var stream = client.GetStream();
            sslStream = new SslStream(stream, false, RemoteCertificateValidationCallback);

            var clientCert = _identityManager.GetTlsCertificate();

            var options = new SslClientAuthenticationOptions
            {
                TargetHost = host, // Could be instance name or anything, we don't validate hostname
                ClientCertificates = new X509CertificateCollection { clientCert },
                EnabledSslProtocols = SslProtocols.Tls13 | SslProtocols.Tls12,
                CertificateRevocationCheckMode = X509RevocationMode.NoCheck
            };

            await sslStream.AuthenticateAsClientAsync(options, linkedToken);

            var remoteCert = sslStream.RemoteCertificate as X509Certificate2 ??
                X509CertificateLoader.LoadCertificate(sslStream.RemoteCertificate!.GetRawCertData());
            var deviceId = ExtractDeviceIdFromCertificate(remoteCert);
            await ValidatePeerBeforeHandshakeAsync(remoteCert, deviceId);
            var session = new ActiveSession(sslStream, client, deviceId, isInitiator: true);

            await CompleteSessionHandshakeAsync(session, remoteCert, linkedToken);
            PersistAuthorizedPeer(remoteCert, deviceId);
            var registration = RegisterOrReuseSession(deviceId, session);
            if (registration == SessionRegistrationResult.Conflict)
            {
                throw new InvalidOperationException($"A session for {deviceId} is already registered but not reusable.");
            }
            if (registration == SessionRegistrationResult.ReusedExisting)
            {
                return deviceId;
            }
            TrackBackgroundTask(RunSessionLifetimeAsync(session, _shutdownCts.Token), "outbound session loop");
            return deviceId;
        }
        catch
        {
            sslStream?.Dispose();
            client.Dispose();
            throw;
        }
    }

    private async Task SessionLoopAsync(SslStream sslStream, TcpClient client, CancellationToken cancellationToken)
    {
        var remoteCert = sslStream.RemoteCertificate as X509Certificate2 ?? X509CertificateLoader.LoadCertificate(sslStream.RemoteCertificate!.GetRawCertData());
        string deviceId;
        try
        {
            deviceId = ExtractDeviceIdFromCertificate(remoteCert);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to extract identity from peer certificate.");
            client.Close();
            return;
        }

        var session = new ActiveSession(sslStream, client, deviceId, isInitiator: false);
        await RunInboundSessionCoreAsync(
            deviceId,
            token => CompleteInboundHandshakeAndRegistrationAsync(
                remoteCert,
                deviceId,
                token => CompleteSessionHandshakeAsync(session, remoteCert, token),
                () => PersistAuthorizedPeer(remoteCert, deviceId),
                () => RegisterOrReuseSession(deviceId, session),
                token),
            _ => RunSessionLifetimeAsync(session, cancellationToken),
            () =>
            {
                _sessions.TryRemove(deviceId, out _);
                session.Dispose();
            },
            cancellationToken);
    }

    internal async Task<SessionRegistrationResult> CompleteInboundHandshakeAndRegistrationAsync(
        X509Certificate2 remoteCert,
        string deviceId,
        Func<CancellationToken, Task> completeHandshake,
        Action persistAuthorizedPeer,
        Func<SessionRegistrationResult> tryAddSession,
        CancellationToken cancellationToken)
    {
        await ValidatePeerBeforeHandshakeAsync(remoteCert, deviceId);
        await completeHandshake(cancellationToken);
        persistAuthorizedPeer();
        var registration = tryAddSession();
        if (registration == SessionRegistrationResult.Conflict)
        {
            throw new InvalidOperationException($"A session for {deviceId} is already registered.");
        }
        if (registration == SessionRegistrationResult.ReusedExisting)
        {
            _logger.LogInformation("Reused existing authenticated session for peer {DeviceId} after duplicate inbound registration.", deviceId);
        }
        return registration;
    }

    private SessionRegistrationResult RegisterOrReuseSession(string deviceId, ActiveSession session)
    {
        if (_sessions.TryAdd(deviceId, session))
        {
            return SessionRegistrationResult.RegisteredNew;
        }

        if (_sessions.TryGetValue(deviceId, out var existingSession) && existingSession.IsAuthenticated)
        {
            _logger.LogInformation("Keeping existing authenticated session for peer {DeviceId} and dropping duplicate fresh connection.", deviceId);
            session.Dispose();
            return SessionRegistrationResult.ReusedExisting;
        }

        session.Dispose();
        return SessionRegistrationResult.Conflict;
    }

    internal bool ShouldAllowProtectedTraffic(string deviceId)
    {
        if (_trustStore is null)
        {
            return false;
        }

        var peer = _trustStore.GetPeer(deviceId);
        return peer?.State == TrustState.Trusted;
    }

    private async Task CompleteSessionHandshakeAsync(ActiveSession session, X509Certificate2 remoteCert, CancellationToken cancellationToken)
    {
        _logger.LogInformation("Session bootstrap starting for peer {DeviceId}. Sending session.hello.", session.DeviceId);
        await _sessionBootstrap.SendSessionHelloAsync(session.Stream, remoteCert.GetRawCertData(), cancellationToken);

        var firstPayload = await ReadFramePayloadAsync(session.Stream, RiftFrame.MaxPreAuthSize, cancellationToken);
        if (firstPayload is null)
        {
            var ex = new InvalidOperationException("Peer closed connection before sending session.hello.");
            ex.Data["DeviceId"] = session.DeviceId;
            throw ex;
        }
        var firstMessageType = GetMessageType(firstPayload);
        if (string.Equals(firstMessageType, "session.hello", StringComparison.Ordinal))
        {
            _logger.LogInformation("Received session.hello from peer {DeviceId}.", session.DeviceId);
            VerifySessionControlMessage(session.Stream, remoteCert, firstPayload, expectedType: "session.hello");

            _logger.LogInformation("Sending session.accept to peer {DeviceId}.", session.DeviceId);
            await _sessionBootstrap.SendSessionAcceptAsync(session.Stream, remoteCert.GetRawCertData(), cancellationToken);

            var acceptPayload = await ReadFramePayloadAsync(session.Stream, RiftFrame.MaxPreAuthSize, cancellationToken);
            if (acceptPayload is null)
            {
                throw new InvalidOperationException("Peer closed connection before sending session.accept.");
            }
            _logger.LogInformation("Received session.accept from peer {DeviceId}.", session.DeviceId);
            VerifySessionControlMessage(session.Stream, remoteCert, acceptPayload, expectedType: "session.accept");
        }
        else if (session.IsInitiator && string.Equals(firstMessageType, "session.accept", StringComparison.Ordinal))
        {
            _logger.LogInformation(
                "Received session.accept from peer {DeviceId} without a preceding peer session.hello. Accepting responder-style handshake.",
                session.DeviceId);
            VerifySessionControlMessage(session.Stream, remoteCert, firstPayload, expectedType: "session.accept");
        }
        else
        {
            throw new InvalidOperationException(
                $"Expected session.hello or session.accept but received {firstMessageType ?? "<null>"}.");
        }

        _logger.LogInformation("Session control messages verified for peer {DeviceId}. Starting capability negotiation.", session.DeviceId);
        session.SelectedCapabilities = await _sessionCapabilityCoordinator.NegotiateAsync(
            session.Stream,
            _identityManager.GetDeviceId(),
            session.DeviceId,
            session.IsInitiator,
            ReadNegotiationFramePayloadAsync,
            cancellationToken);
        var allowsProtectedTraffic = ShouldAllowProtectedTraffic(session.DeviceId);
        _logger.LogInformation("Capability negotiation completed for peer {DeviceId}. AllowsProtectedTraffic={AllowsProtectedTraffic}.", session.DeviceId, allowsProtectedTraffic);
        session.AllowsProtectedTraffic = allowsProtectedTraffic;
        session.PeerContext = new SessionPeerContext(
            session.DeviceId,
            session.SelectedCapabilities.Select(capability => capability.Name).ToArray(),
            session.AllowsProtectedTraffic);
        session.IsAuthenticated = true;
    }

    private static string? GetMessageType(byte[] payloadBuffer)
    {
        using var document = JsonDocument.Parse(payloadBuffer);
        return document.RootElement.GetProperty("type").GetString();
    }

    private static async Task<byte[]?> ReadNegotiationFramePayloadAsync(Stream stream, int maxFrameSize, CancellationToken cancellationToken)
    {
        using var timeoutCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeoutCts.CancelAfter(CapabilityNegotiationTimeout);
        return await ReadFramePayloadAsync(stream, maxFrameSize, timeoutCts.Token);
    }

    private async Task RunRegisteredSessionLoopAsync(ActiveSession session, CancellationToken cancellationToken)
    {
        while (!cancellationToken.IsCancellationRequested)
        {
            var payloadBuffer = await ReadFramePayloadAsync(session.Stream, GetMaxInboundFrameSize(session.IsAuthenticated), cancellationToken);
            if (payloadBuffer is null)
            {
                break;
            }

            MessageReceived?.Invoke(this, new MessageReceivedEventArgs(
                session.DeviceId,
                payloadBuffer,
                session.PeerContext));
        }
    }

    private async Task RunSessionLifetimeAsync(ActiveSession session, CancellationToken cancellationToken)
    {
        await RunSessionLifetimeCoreAsync(
            session.DeviceId,
            session.SelectedCapabilities,
            session.AllowsProtectedTraffic,
            token => RunRegisteredSessionLoopAsync(session, token),
            () =>
            {
                _sessions.TryRemove(session.DeviceId, out _);
                session.Dispose();
            },
            cancellationToken);
    }

    internal async Task RunSessionLifetimeCoreAsync(
        string deviceId,
        IReadOnlyList<CapabilityDescriptor> selectedCapabilities,
        bool allowsProtectedTraffic,
        Func<CancellationToken, Task> sessionLoop,
        Action cleanup,
        CancellationToken cancellationToken)
    {
        var capabilityNames = selectedCapabilities.Select(capability => capability.Name).ToArray();

        try
        {
            SessionStateChanged?.Invoke(this, new SessionStateChangedEventArgs(
                deviceId,
                isOnline: true,
                capabilityNames,
                allowsProtectedTraffic));
            await sessionLoop(cancellationToken);
        }
        finally
        {
            cleanup();
            SessionStateChanged?.Invoke(this, new SessionStateChangedEventArgs(
                deviceId,
                isOnline: false,
                capabilityNames,
                allowsProtectedTraffic));
        }
    }

    internal async Task RunInboundSessionCoreAsync(
        string deviceId,
        Func<CancellationToken, Task<SessionRegistrationResult>> handshakeAndRegister,
        Func<CancellationToken, Task> sessionLifetime,
        Action cleanup,
        CancellationToken cancellationToken)
    {
        var lifetimeManaged = false;
        var registration = SessionRegistrationResult.Conflict;

        try
        {
            registration = await handshakeAndRegister(cancellationToken);
            if (registration == SessionRegistrationResult.ReusedExisting)
            {
                return;
            }
            lifetimeManaged = true;
            await sessionLifetime(cancellationToken);
        }
        catch (Exception ex)
        {
            if (IsExpectedSessionTermination(ex, cancellationToken))
            {
                _logger.LogDebug(ex, "Session loop ended for peer {DeviceId}.", deviceId);
            }
            else
            {
                _logger.LogWarning(ex, "Session loop error for peer {DeviceId}", deviceId);
            }
        }
        finally
        {
            if (!lifetimeManaged && registration != SessionRegistrationResult.ReusedExisting)
            {
                cleanup();
            }
        }
    }

    private void VerifySessionControlMessage(SslStream sslStream, X509Certificate2 remoteCert, byte[] payloadBuffer, string expectedType)
    {
        try
        {
            using var document = JsonDocument.Parse(payloadBuffer);
            var root = document.RootElement;
            var certificateDeviceId = ExtractDeviceIdFromCertificate(remoteCert);

            var messageType = root.GetProperty("type").GetString();
            if (!string.Equals(messageType, expectedType, StringComparison.Ordinal))
            {
                throw new InvalidOperationException(
                    $"Expected {expectedType} but received {messageType ?? "<null>"}.");
            }

            var sourceDeviceId = root.GetProperty("sourceDeviceId").GetString();
            if (!string.Equals(sourceDeviceId, certificateDeviceId, StringComparison.Ordinal))
            {
                throw new InvalidOperationException($"{expectedType} sourceDeviceId did not match the TLS-authenticated device identity.");
            }

            var payload = root.GetProperty("payload");
            var payloadDeviceId = payload.GetProperty("deviceId").GetString();
            if (!string.Equals(payloadDeviceId, certificateDeviceId, StringComparison.Ordinal))
            {
                throw new InvalidOperationException($"{expectedType} payload.deviceId did not match the TLS-authenticated device identity.");
            }

            var identityProofHex = payload.GetProperty("identityProof").GetString();
            if (string.IsNullOrWhiteSpace(identityProofHex))
            {
                throw new InvalidOperationException($"{expectedType} did not include identityProof.");
            }

            var bindingType = payload.GetProperty("bindingType").GetString();
            if (string.IsNullOrWhiteSpace(bindingType))
            {
                throw new InvalidOperationException($"{expectedType} did not include bindingType.");
            }

            if (bindingType is not ("tls-exporter" or "tls-unique" or "app-nonce"))
            {
                throw new InvalidOperationException($"{expectedType} contained unrecognized bindingType '{bindingType}'.");
            }

            byte[]? peerSessionNonce = null;
            if (bindingType == "app-nonce")
            {
                var nonceStr = payload.GetProperty("sessionNonce").GetString();
                if (string.IsNullOrWhiteSpace(nonceStr))
                {
                    throw new InvalidOperationException($"{expectedType} app-nonce binding requires sessionNonce.");
                }
                peerSessionNonce = Convert.FromBase64String(nonceStr);
                if (peerSessionNonce.Length != 32)
                {
                    throw new InvalidOperationException($"{expectedType} sessionNonce must be exactly 32 bytes, got {peerSessionNonce.Length}.");
                }
            }

            var signatureBytes = Convert.FromHexString(identityProofHex);
            var peerEd25519PubKey = ExtractEd25519PublicKeyFromCertificate(remoteCert);
            if (!_sessionBootstrap.VerifyIdentityProof(sslStream, peerEd25519PubKey, remoteCert, signatureBytes, bindingType, peerSessionNonce))
            {
                throw new InvalidOperationException($"{expectedType} identityProof verification failed.");
            }
        }
        catch (KeyNotFoundException ex)
        {
            throw new InvalidOperationException($"{expectedType} payload was missing required fields.", ex);
        }
        catch (JsonException ex)
        {
            throw new InvalidOperationException($"{expectedType} payload was not valid JSON.", ex);
        }
        catch (FormatException ex)
        {
            throw new InvalidOperationException($"{expectedType} identityProof was not valid lowercase hexadecimal.", ex);
        }
    }

    internal async Task ValidatePeerBeforeHandshakeAsync(X509Certificate2 remoteCert, string deviceId)
    {
        if (_trustStore is null)
        {
            return;
        }

        var peerPublicKey = ExtractEd25519PublicKeyFromCertificate(remoteCert);
        var certificateFingerprint = remoteCert.GetCertHashString(System.Security.Cryptography.HashAlgorithmName.SHA256).ToLowerInvariant();
        var existingPeer = _trustStore.GetPeer(deviceId);

        if (existingPeer is null)
        {
            return;
        }

        if (existingPeer.Ed25519PublicKey is not null && !existingPeer.Ed25519PublicKey.SequenceEqual(peerPublicKey))
        {
            await LogSecurityEventAsync(SecurityEventTypes.AuthFailed, deviceId, SecurityEventSeverity.Critical, SecurityEventOutcome.Failure, "AuthenticationFailed");
            throw new InvalidOperationException("Peer Ed25519 identity did not match the stored trust-store entry.");
        }

        if (existingPeer.State == TrustState.Revoked)
        {
            _trustStore.DeletePeer(deviceId);
            await LogSecurityEventAsync(SecurityEventTypes.ConnectionRejected, deviceId, SecurityEventSeverity.Warning, SecurityEventOutcome.Denied, "Unauthorized");
            throw new UnauthorizedAccessException("Peer identity is revoked.");
        }

        if (existingPeer.State == TrustState.Blocked)
        {
            await LogSecurityEventAsync(SecurityEventTypes.ConnectionRejected, deviceId, SecurityEventSeverity.Warning, SecurityEventOutcome.Denied, "Unauthorized");
            throw new UnauthorizedAccessException("Peer identity is blocked.");
        }
    }

    internal void PersistAuthorizedPeer(X509Certificate2 remoteCert, string deviceId)
    {
        if (_trustStore is null)
        {
            return;
        }

        var peerPublicKey = ExtractEd25519PublicKeyFromCertificate(remoteCert);
        var certificateFingerprint = remoteCert.GetCertHashString(System.Security.Cryptography.HashAlgorithmName.SHA256).ToLowerInvariant();
        var existingPeer = _trustStore.GetPeer(deviceId);

        if (existingPeer is null)
        {
            _trustStore.SavePeer(new PeerIdentity
            {
                DeviceId = deviceId,
                Ed25519PublicKey = peerPublicKey,
                State = TrustState.Discovered,
                EcdsaCertificateFingerprint = certificateFingerprint,
                LastStateTransitionAt = DateTimeOffset.UtcNow
            });
            return;
        }

        existingPeer.Ed25519PublicKey ??= peerPublicKey;
        existingPeer.EcdsaCertificateFingerprint = certificateFingerprint;
        _trustStore.SavePeer(existingPeer);
    }

    private Task LogSecurityEventAsync(
        string eventType,
        string peerDeviceId,
        SecurityEventSeverity severity,
        SecurityEventOutcome outcome,
        string? failureReason)
    {
        if (_securityEventLog is null)
        {
            return Task.CompletedTask;
        }

        return _securityEventLog.LogEventAsync(new SecurityEventRecord
        {
            EventType = eventType,
            Severity = severity,
            LocalDeviceId = _identityManager.GetDeviceId(),
            PeerDeviceId = peerDeviceId,
            Outcome = outcome,
            FailureReason = failureReason
        });
    }

    private static async Task<byte[]?> ReadFramePayloadAsync(Stream stream, int maxFrameSize, CancellationToken cancellationToken)
    {
        var headerBuffer = new byte[RiftFrame.LengthPrefixBytes];
        int headerRead = await ReadExactAsync(stream, headerBuffer, cancellationToken);
        if (headerRead == 0)
        {
            return null;
        }

        uint payloadLength = System.Buffers.Binary.BinaryPrimitives.ReadUInt32BigEndian(headerBuffer);
        if (payloadLength > maxFrameSize)
        {
            throw new InvalidOperationException("PayloadTooLarge");
        }

        var payloadBuffer = new byte[payloadLength];
        int payloadRead = await ReadExactAsync(stream, payloadBuffer, cancellationToken);
        if (payloadRead == 0)
        {
            return null;
        }

        return payloadBuffer;
    }

    private static async Task<int> ReadExactAsync(Stream stream, byte[] buffer, CancellationToken cancellationToken)
    {
        int totalRead = 0;
        while (totalRead < buffer.Length)
        {
            int read = await stream.ReadAsync(buffer, totalRead, buffer.Length - totalRead, cancellationToken);
            if (read == 0) return 0;
            totalRead += read;
        }
        return totalRead;
    }

    private static bool IsExpectedSessionTermination(Exception ex, CancellationToken cancellationToken)
    {
        if (ex is OperationCanceledException)
        {
            return true;
        }

        if (cancellationToken.IsCancellationRequested)
        {
            return true;
        }

        if (ex is IOException ioEx)
        {
            if (ioEx.InnerException is SocketException socketEx)
            {
                if (socketEx.SocketErrorCode is SocketError.OperationAborted or SocketError.Interrupted)
                {
                    return true;
                }
            }

            if (ioEx.Message.Contains("Operation canceled", StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }
        }

        return false;
    }

    private bool RemoteCertificateValidationCallback(object sender, X509Certificate? certificate, X509Chain? chain, SslPolicyErrors sslPolicyErrors)
    {
        // For Rift, we do not require the certificate to be signed by a trusted CA.
        // We only care about extracting the Ed25519 identity. The actual trust is evaluated post-handshake.
        return certificate != null;
    }

    internal static string ExtractDeviceIdFromCertificate(X509Certificate2 cert)
    {
        var edKeyBytes = ExtractEd25519PublicKeyFromCertificate(cert);
        return IdentityManager.DeriveDeviceId(edKeyBytes);
    }

    internal static byte[] ExtractEd25519PublicKeyFromCertificate(X509Certificate2 cert)
    {
        var parser = new BouncyCertificateParser();
        var parsedCertificate = parser.ReadCertificate(cert.RawData);
        var extension = parsedCertificate.GetExtensionValue(new DerObjectIdentifier("2.25.293029629918709742181702189012786017422"));
        if (extension is not null)
        {
            var rawData = extension.GetOctets();
            if (rawData.Length == 36 && rawData[0] == 0x04 && rawData[1] == 0x22 && rawData[2] == 0x04 && rawData[3] == 0x20)
            {
                var edKeyBytes = new byte[32];
                Array.Copy(rawData, 4, edKeyBytes, 0, 32);
                return edKeyBytes;
            }
            else if (rawData.Length == 34 && rawData[0] == 0x04 && rawData[1] == 0x20)
            {
                var edKeyBytes = new byte[32];
                Array.Copy(rawData, 2, edKeyBytes, 0, 32);
                return edKeyBytes;
            }
        }

        throw new InvalidOperationException("Certificate does not contain a valid Rift Ed25519 identity extension.");
    }

    public async Task SendAsync(string peerDeviceId, ReadOnlyMemory<byte> frameBody, CancellationToken cancellationToken)
    {
        if (_sessions.TryGetValue(peerDeviceId, out var session))
        {
            int maxFrameSize = GetMaxOutboundFrameSize(session.IsAuthenticated);
            if (frameBody.Length > maxFrameSize)
                throw new InvalidOperationException("PayloadTooLarge");
                 
            var frame = RiftFrame.Encode(frameBody.Span);
            await session.WriteGate.RunAsync(
                writeCancellationToken => session.Stream.WriteAsync(frame, writeCancellationToken).AsTask(),
                cancellationToken).ConfigureAwait(false);
        }
        else
        {
            throw new InvalidOperationException($"No open session exists for {peerDeviceId}.");
        }
    }

    public bool HasActiveSession(string peerDeviceId)
    {
        return _sessions.TryGetValue(peerDeviceId, out var session) && session.IsAuthenticated;
    }

    public bool HasProtectedSession(string peerDeviceId)
    {
        return _sessions.TryGetValue(peerDeviceId, out var session) &&
            session.IsAuthenticated &&
            session.AllowsProtectedTraffic;
    }

    public void RefreshSessionAuthorization(string peerDeviceId)
    {
        if (!_sessions.TryGetValue(peerDeviceId, out var session) || !session.IsAuthenticated)
        {
            return;
        }

        var allowsProtectedTraffic = ShouldAllowProtectedTraffic(peerDeviceId);
        if (session.AllowsProtectedTraffic == allowsProtectedTraffic)
        {
            return;
        }

        session.AllowsProtectedTraffic = allowsProtectedTraffic;
        session.PeerContext = new SessionPeerContext(
            session.DeviceId,
            session.SelectedCapabilities.Select(capability => capability.Name).ToArray(),
            allowsProtectedTraffic);

        SessionStateChanged?.Invoke(this, new SessionStateChangedEventArgs(
            peerDeviceId,
            isOnline: true,
            session.SelectedCapabilities.Select(capability => capability.Name).ToArray(),
            allowsProtectedTraffic));
    }

    public PeerSessionEndpoint? GetPeerSessionEndpoint(string peerDeviceId)
    {
        if (!_sessions.TryGetValue(peerDeviceId, out var session))
        {
            return null;
        }

        if (session.Client.Client.RemoteEndPoint is not IPEndPoint remoteEndPoint)
        {
            return null;
        }

        return new PeerSessionEndpoint(remoteEndPoint.Address.ToString(), remoteEndPoint.Port);
    }

    public Task DisconnectPeerAsync(string peerDeviceId, CancellationToken cancellationToken)
    {
        if (_sessions.TryRemove(peerDeviceId, out var session))
        {
            SessionStateChanged?.Invoke(this, new SessionStateChangedEventArgs(
                peerDeviceId,
                isOnline: false,
                session.SelectedCapabilities.Select(capability => capability.Name).ToArray(),
                session.AllowsProtectedTraffic));
            session.Dispose();
        }
        return Task.CompletedTask;
    }

    public void Dispose()
    {
        _shutdownCts.Cancel();
        _listener?.Stop();
        if (!_backgroundTasks.IsEmpty)
        {
            _logger.LogDebug("Transport disposed with {PendingTaskCount} background task(s) still completing.", _backgroundTasks.Count);
        }

        foreach (var session in _sessions.Values)
        {
            session.Dispose();
        }
        _sessions.Clear();
        _shutdownCts.Dispose();
    }

    private void TrackBackgroundTask(Task task, string operation)
    {
        int taskId = Interlocked.Increment(ref _nextBackgroundTaskId);
        _backgroundTasks.TryAdd(taskId, task);

        _ = task.ContinueWith(
            completedTask =>
            {
                _backgroundTasks.TryRemove(taskId, out _);

                if (completedTask.IsFaulted)
                {
                    _logger.LogError(completedTask.Exception, "Background task failed during {Operation}.", operation);
                }
            },
            CancellationToken.None,
            TaskContinuationOptions.ExecuteSynchronously,
            TaskScheduler.Default);
    }

    internal static int GetMaxInboundFrameSize(bool isAuthenticated)
    {
        return isAuthenticated ? RiftFrame.MaxPostAuthSize : RiftFrame.MaxPreAuthSize;
    }

    internal static int GetMaxOutboundFrameSize(bool isAuthenticated)
    {
        return isAuthenticated ? RiftFrame.MaxPostAuthSize : RiftFrame.MaxPreAuthSize;
    }

    private class ActiveSession : IDisposable
    {
        public SslStream Stream { get; }
        public TcpClient Client { get; }
        public string DeviceId { get; }
        public bool IsInitiator { get; }
        public bool IsAuthenticated { get; set; }
        public IReadOnlyList<CapabilityDescriptor> SelectedCapabilities { get; set; }
        public bool AllowsProtectedTraffic { get; set; }
        public SessionPeerContext PeerContext { get; set; }
        public SessionWriteGate WriteGate { get; } = new();

        public ActiveSession(SslStream stream, TcpClient client, string deviceId, bool isInitiator)
        {
            Stream = stream;
            Client = client;
            DeviceId = deviceId;
            IsInitiator = isInitiator;
            IsAuthenticated = false;
            SelectedCapabilities = [];
            AllowsProtectedTraffic = false;
            PeerContext = new SessionPeerContext(deviceId, Array.Empty<string>(), allowsProtectedTraffic: false);
        }

        public void Dispose()
        {
            WriteGate.Dispose();
            Stream.Dispose();
            Client.Dispose();
        }
    }

    internal enum SessionRegistrationResult
    {
        Conflict,
        RegisteredNew,
        ReusedExisting
    }
}
