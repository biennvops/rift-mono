using Rift.Daemon.Core.Interfaces;
using System.Runtime.InteropServices;

namespace Rift.Daemon.Core;

public sealed class DaemonInfoService(
    IIdentityManager identityManager,
    ISecurityEventLog securityEventLog,
    ITrustStore trustStore,
    IDiscoveryCoordinator discoveryCoordinator,
    IPresenceService presenceService,
    ITransport transport,
    IUnixIdentityProtectionKeyProvider? identityProtectionKeyProvider = null) : IDaemonInfoService
{
    private static readonly CapabilityInfo[] Capabilities =
    [
        DaemonCapabilities.ClipboardOfferFetch,
        DaemonCapabilities.FileTransfer,
        DaemonCapabilities.MediaPlayback,
        DaemonCapabilities.NotificationSync,
        DaemonCapabilities.PresenceBasic,
        DaemonCapabilities.OperationLifecycle,
        DaemonCapabilities.SecurityEventLog
    ];

    public DeviceInfoResult GetDeviceInfo()
    {

        return new DeviceInfoResult
        {
            DeviceId = identityManager.GetDeviceId(),
            DisplayName = identityManager.GetDisplayName(),
            Platform = GetLocalPlatform(),
            Fingerprint = identityManager.GetFingerprint(),
            ImplementationId = "riftd-cs/0.1.0",
            ProtocolVersion = "0.1-draft",
            IdentityProtectionBackend = GetIdentityProtectionBackend(identityProtectionKeyProvider),
            Capabilities = Capabilities
        };
    }

    public SetDisplayNameResult SetDisplayName(string displayName)
    {
        identityManager.SetDisplayName(displayName);
        
        _ = securityEventLog.LogEventAsync(new SecurityEventRecord
        {
            EventType = SecurityEventTypes.IdentityUpdated,
            Severity = SecurityEventSeverity.Info,
            LocalDeviceId = identityManager.GetDeviceId(),
            Outcome = SecurityEventOutcome.Success,
            Details = new Dictionary<string, object>
            {
                { "displayName", displayName },
                { "source", "local" }
            }
        });
        
        _ = Task.Run(async () =>
        {
            var connectedPeers = trustStore.GetAllPeers().Where(p => p.State == TrustState.Trusted);
            var envelope = new
            {
                rift = "0.1-draft",
                type = "identity.update",
                messageId = Guid.NewGuid().ToString("D"),
                sourceDeviceId = identityManager.GetDeviceId(),
                payload = new
                {
                    deviceId = identityManager.GetDeviceId(),
                    displayName = displayName
                }
            };
            var payloadBytes = System.Text.Encoding.UTF8.GetBytes(System.Text.Json.JsonSerializer.Serialize(envelope));
            foreach (var peer in connectedPeers)
            {
                if (transport.HasProtectedSession(peer.DeviceId))
                {
                    try
                    {
                        await transport.SendAsync(peer.DeviceId, payloadBytes, CancellationToken.None);
                    }
                    catch (Exception)
                    {
                        // Ignore broadcast failure
                    }
                }
            }
        });

        return new SetDisplayNameResult { DisplayName = displayName };
    }

    public async Task<QueryEventLogResult> QueryEventLogAsync(SecurityEventQuery query)
    {
        var events = await securityEventLog.QueryEventsAsync(query);
        return new QueryEventLogResult
        {
            Events = events,
            Total = events.Count
        };
    }

    public ListTrustedPeersResult ListTrustedPeers()
    {
        var peers = trustStore.GetAllPeers()
            .Where(peer => peer.State is not (TrustState.Discovered or TrustState.Revoked))
            .Select(peer =>
            {
                var presence = presenceService.GetPeerPresence(peer.DeviceId);
                return new TrustedPeerInfo
                {
                    DeviceId = peer.DeviceId,
                    DisplayName = peer.DisplayName,
                    Platform = NormalizePlatform(peer.Platform, peer.DisplayName),
                    TrustState = peer.State.ToString().ToLowerInvariant(),
                    PairedAt = peer.State == TrustState.Trusted ? peer.LastStateTransitionAt.ToString("O") : null,
                    LastSeenAt = presence?.LastSeenAt,
                    Presence = presence?.Status ?? "offline",
                    Capabilities = presence?.Capabilities ?? []
                };
            })
            .ToArray();

        return new ListTrustedPeersResult
        {
            Peers = peers
        };
    }

    public ListDiscoveredPeersResult ListDiscoveredPeers()
    {
        var activeDiscoveries = discoveryCoordinator.ListDiscoveredPeers();
        
        var discoveredFromTrustStore = trustStore.GetAllPeers()
            .Where(p => p.State == TrustState.Discovered)
            .Select(p => new { Peer = p, Endpoint = transport.GetPeerSessionEndpoint(p.DeviceId) })
            .Where(x => x.Endpoint != null)
            .Select(x => new DiscoveredPeerInfo
            {
                DeviceId = x.Peer.DeviceId,
                DisplayName = x.Peer.DisplayName,
                Platform = NormalizePlatform(x.Peer.Platform, x.Peer.DisplayName),
                InstanceId = x.Peer.DeviceId,
                Address = x.Endpoint!.Address,
                Port = x.Endpoint!.Port,
                TrustState = "discovered",
                TxtRecord = new Dictionary<string, string>(),
                ObservedEndpoints = [new DiscoveredPeerEndpoint { Address = x.Endpoint!.Address, Port = x.Endpoint!.Port }]
            })
            .Where(p => !activeDiscoveries.Peers.Any(d => string.Equals(d.DeviceId, p.DeviceId, StringComparison.Ordinal)))
            .ToArray();

        if (discoveredFromTrustStore.Length == 0)
        {
            return activeDiscoveries;
        }

        return new ListDiscoveredPeersResult
        {
            Peers = activeDiscoveries.Peers.Concat(discoveredFromTrustStore).ToArray(),
            IsDiscovering = activeDiscoveries.IsDiscovering
        };
    }

    private static string GetIdentityProtectionBackend(
        IUnixIdentityProtectionKeyProvider? identityProtectionKeyProvider)
    {
        if (OperatingSystem.IsWindows())
        {
            return "dpapi";
        }
        if (OperatingSystem.IsMacOS())
        {
            return "keychain";
        }
        if (OperatingSystem.IsLinux())
        {
            return identityProtectionKeyProvider?.BackendName ?? "file";
        }
        return "unknown";
    }

    private static string GetLocalPlatform()
    {
        if (RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
        {
            return "windows";
        }

        if (RuntimeInformation.IsOSPlatform(OSPlatform.OSX))
        {
            return "macos";
        }

        if (RuntimeInformation.IsOSPlatform(OSPlatform.Linux))
        {
            return "linux";
        }

        return "unknown";
    }

    internal static string NormalizePlatform(string? platform, string? displayName)
    {
        if (!string.IsNullOrWhiteSpace(platform) && platform != "unknown")
        {
            return platform;
        }

        if (string.IsNullOrWhiteSpace(displayName))
        {
            return "unknown";
        }

        if (displayName.StartsWith("Android ", StringComparison.OrdinalIgnoreCase))
        {
            return "android";
        }

        if (displayName.StartsWith("Windows ", StringComparison.OrdinalIgnoreCase))
        {
            return "windows";
        }

        if (displayName.StartsWith("macOS ", StringComparison.OrdinalIgnoreCase))
        {
            return "macos";
        }

        if (displayName.StartsWith("Linux ", StringComparison.OrdinalIgnoreCase))
        {
            return "linux";
        }

        return "unknown";
    }

    public GetPeerPresenceResult GetPeerPresence(string deviceId)
    {
        var peer = trustStore.GetPeer(deviceId);
        if (peer is null)
        {
            throw new InvalidOperationException($"Peer '{deviceId}' was not found.");
        }

        if (peer.State != TrustState.Trusted)
        {
            throw new UnauthorizedAccessException("Peer is not trusted.");
        }

        var presence = presenceService.GetPeerPresence(deviceId);
        return new GetPeerPresenceResult
        {
                DeviceId = peer.DeviceId,
            Status = presence?.Status ?? "offline",
            LastSeenAt = presence?.LastSeenAt,
            Capabilities = presence?.Capabilities ?? []
        };
    }
}
