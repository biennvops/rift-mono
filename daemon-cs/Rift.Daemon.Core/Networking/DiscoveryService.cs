using System;
using System.Collections.Generic;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Net.NetworkInformation;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Makaretu.Dns;
using Microsoft.Extensions.Logging;
using Rift.Daemon.Core.Interfaces;

namespace Rift.Daemon.Core.Networking;

public sealed class DiscoveryService : IDiscoveryService, IDisposable
{
    private readonly ILogger<DiscoveryService> _logger;
    private readonly MulticastService _mdns;
    private readonly ServiceDiscovery _serviceDiscovery;
    private readonly object _syncRoot = new();
    private readonly CancellationTokenSource _shutdownCts = new();
    private readonly DiscoveryAnnouncementGate _announcementGate = new();
    private ServiceProfile? _profile;
    private string? _advertisedDeviceId;
    private bool _isAdvertising;
    private bool _isDiscovering;
    private bool _isMdnsRunning;
    private UdpClient? _fallbackAdvertiser;
    private Task? _fallbackAdvertiserTask;
    private UdpClient? _fallbackDiscoveryListener;
    private Task? _fallbackDiscoveryTask;
    private readonly System.Collections.Concurrent.ConcurrentDictionary<IPAddress, DateTimeOffset> _fallbackPingPongTargets = new();
    private IReadOnlyList<FallbackBroadcastTarget> _fallbackBroadcastTargets = [];
    private DateTimeOffset _fallbackBroadcastTargetsRefreshedAt = DateTimeOffset.MinValue;
    private int _networkRefreshQueued;
    private Timer? _networkRefreshDebounceTimer;
    private readonly bool _subscribedToNetworkChanges;

    public event EventHandler<PeerDiscoveredEventArgs>? PeerDiscovered;

    public DiscoveryService(ILogger<DiscoveryService> logger)
    {
        _logger = logger;
        _mdns = new MulticastService();
        _serviceDiscovery = new ServiceDiscovery(_mdns);

        _serviceDiscovery.ServiceInstanceDiscovered += OnServiceInstanceDiscovered;
        _subscribedToNetworkChanges = ShouldSubscribeToNetworkChanges(OperatingSystem.IsMacOS());
        if (_subscribedToNetworkChanges)
        {
            NetworkChange.NetworkAddressChanged += OnNetworkAddressChanged;
            NetworkChange.NetworkAvailabilityChanged += OnNetworkAvailabilityChanged;
        }
    }

    public void StartAdvertising(string deviceId, string minVersion, string maxVersion)
    {
        lock (_syncRoot)
        {
            if (_profile != null)
            {
                _logger.LogWarning("Advertising is already started.");
                return;
            }

            // spec §4.1: The service instance name MUST be unique.
            // Implementations SHOULD use an opaque random identifier.
            var instanceName = Guid.NewGuid().ToString("N");

            _profile = new ServiceProfile(instanceName, "_rift._tcp", RiftNetworkDefaults.DefaultPort);

            // spec §4.2: Required TXT records
            _profile.AddProperty("minV", minVersion);
            _profile.AddProperty("maxV", maxVersion);
            _profile.AddProperty("did", deviceId);
            // Optionally add fp if available; here we just use deviceId for recognition
            _advertisedDeviceId = deviceId;

            _serviceDiscovery.Advertise(_profile);
            StartMdnsIfNeeded();
            RefreshFallbackBroadcastTargets(force: true);
            StartFallbackAdvertisingIfNeeded(deviceId, minVersion, maxVersion);
            _isAdvertising = true;

            _logger.LogInformation("Started mDNS advertising for _rift._tcp.local. (Instance: {Instance})", instanceName);
        }
    }

    public void StopAdvertising()
    {
        lock (_syncRoot)
        {
            if (_profile != null)
            {
                _serviceDiscovery.Unadvertise(_profile);
                _profile = null;
                _advertisedDeviceId = null;
                _isAdvertising = false;
                StopFallbackAdvertisingIfIdle();
                StopMdnsIfIdle();
                _logger.LogInformation("Stopped mDNS advertising.");
            }
        }
    }

    public void StartDiscovery()
    {
        lock (_syncRoot)
        {
            if (_isDiscovering)
            {
                _logger.LogWarning("Discovery is already started.");
                return;
            }

            StartMdnsIfNeeded();
            RefreshFallbackBroadcastTargets(force: true);
            StartFallbackDiscoveryIfNeeded();
            _isDiscovering = true;

            // Makaretu's DNS-SD helper issues the correct service-instance
            // browse query and wires responses back into
            // ServiceInstanceDiscovered.
            _serviceDiscovery.QueryServiceInstances("_rift._tcp");

            _logger.LogInformation("Started mDNS discovery for peers.");
        }
    }

    public void StopDiscovery()
    {
        lock (_syncRoot)
        {
            if (!_isDiscovering)
            {
                _logger.LogWarning("Discovery is already stopped.");
                return;
            }

            _isDiscovering = false;
            StopFallbackDiscoveryIfIdle();
            StopMdnsIfIdle();
            _logger.LogInformation("Stopped mDNS discovery for peers.");
        }
    }

    private void StartMdnsIfNeeded()
    {
        if (_isMdnsRunning)
        {
            return;
        }

        try
        {
            _mdns.Start();
            _isMdnsRunning = true;
        }
        catch (Exception ex) when (LocalNetworkPolicy.IsAccessDenied(ex))
        {
            throw new LocalNetworkAccessDeniedException(
                "Local network access is denied by macOS privacy settings.",
                ex);
        }
    }

    private void StopMdnsIfIdle()
    {
        if (_isAdvertising || _isDiscovering || !_isMdnsRunning)
        {
            return;
        }

        _mdns.Stop();
        _isMdnsRunning = false;
    }

    private void StartFallbackAdvertisingIfNeeded(string deviceId, string minVersion, string maxVersion)
    {
        if (_fallbackAdvertiserTask is { IsCompleted: false } || _fallbackAdvertiser is not null)
        {
            return;
        }

        try
        {
            var client = new UdpClient(AddressFamily.InterNetwork)
            {
                EnableBroadcast = true
            };
            var instanceId = _profile?.InstanceName.ToString() ?? Guid.NewGuid().ToString("N");
            _fallbackAdvertiser = client;
            _fallbackAdvertiserTask = Task.Run(
                () => RunFallbackAdvertiserAsync(client, deviceId, instanceId, minVersion, maxVersion, _shutdownCts.Token),
                _shutdownCts.Token);
        }
        catch (Exception ex) when (LocalNetworkPolicy.IsAccessDenied(ex))
        {
            throw new LocalNetworkAccessDeniedException(
                "Local network access is denied by macOS privacy settings.",
                ex);
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Failed to start UDP fallback advertising.");
        }
    }

    private void StopFallbackAdvertisingIfIdle()
    {
        if (_isAdvertising || _fallbackAdvertiser is null)
        {
            return;
        }

        _fallbackAdvertiser.Dispose();
        _fallbackAdvertiser = null;
        _fallbackAdvertiserTask = null;
    }

    private void StartFallbackDiscoveryIfNeeded()
    {
        if (_fallbackDiscoveryTask is { IsCompleted: false } || _fallbackDiscoveryListener is not null)
        {
            return;
        }

        try
        {
            var client = new UdpClient(new IPEndPoint(IPAddress.Any, RiftNetworkDefaults.FallbackDiscoveryPort))
            {
                EnableBroadcast = true
            };
            _fallbackDiscoveryListener = client;
            _fallbackDiscoveryTask = Task.Run(
                () => RunFallbackDiscoveryAsync(client, _shutdownCts.Token),
                _shutdownCts.Token);
        }
        catch (Exception ex) when (LocalNetworkPolicy.IsAccessDenied(ex))
        {
            throw new LocalNetworkAccessDeniedException(
                "Local network access is denied by macOS privacy settings.",
                ex);
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Failed to start UDP fallback discovery listener.");
        }
    }

    private void StopFallbackDiscoveryIfIdle()
    {
        if (_isDiscovering || _fallbackDiscoveryListener is null)
        {
            return;
        }

        _fallbackDiscoveryListener.Dispose();
        _fallbackDiscoveryListener = null;
        _fallbackDiscoveryTask = null;
    }

    private void OnServiceInstanceDiscovered(object? sender, ServiceInstanceDiscoveryEventArgs e)
    {
        var name = e.ServiceInstanceName.ToString();
        _logger.LogDebug("[mDNS Debug] ServiceDiscovered fired for: {Name}", name);

        lock (_syncRoot)
        {
            if (_profile != null && name.StartsWith(_profile.InstanceName.ToString(), StringComparison.Ordinal))
            {
                return;
            }
        }

        if (!name.Contains("_rift._tcp", StringComparison.OrdinalIgnoreCase))
        {
            return;
        }

        var peerInfo = CreatePeerDiscoveredEventArgs(e);
        PublishPeer(peerInfo, "mDNS");
    }

    private async Task RunFallbackAdvertiserAsync(
        UdpClient client,
        string deviceId,
        string instanceId,
        string minVersion,
        string maxVersion,
        CancellationToken cancellationToken)
    {
        var endpoint = new IPEndPoint(IPAddress.Broadcast, RiftNetworkDefaults.FallbackDiscoveryPort);
        while (!cancellationToken.IsCancellationRequested)
        {
            try
            {
                RefreshFallbackBroadcastTargets();
                var payload = JsonSerializer.Serialize(new Dictionary<string, object?>
                {
                    ["rift"] = "0.1-draft",
                    ["kind"] = "fallback-discovery",
                    ["instanceId"] = instanceId,
                    ["port"] = RiftNetworkDefaults.DefaultPort,
                    ["minV"] = minVersion,
                    ["maxV"] = maxVersion,
                    ["did"] = deviceId
                });
                var bytes = Encoding.UTF8.GetBytes(payload);
                await client.SendAsync(bytes, endpoint, cancellationToken);

                foreach (var broadcastTarget in GetFallbackBroadcastTargets())
                {
                    var subnetBroadcast = new IPEndPoint(
                        broadcastTarget.BroadcastAddress,
                        RiftNetworkDefaults.FallbackDiscoveryPort);
                    try
                    {
                        await client.SendAsync(bytes, subnetBroadcast, cancellationToken);
                    }
                    catch { }
                }

                // Ping-pong: explicitly unicast to all known peers that sent us a beacon recently
                var cutoff = DateTimeOffset.UtcNow.AddSeconds(-30);
                foreach (var kvp in _fallbackPingPongTargets)
                {
                    if (kvp.Value < cutoff)
                    {
                        _fallbackPingPongTargets.TryRemove(kvp.Key, out _);
                        continue;
                    }
                    try {
                        await client.SendAsync(bytes, new IPEndPoint(kvp.Key, RiftNetworkDefaults.FallbackDiscoveryPort), cancellationToken);
                    } catch { /* Ignore individual ping-pong send errors */ }
                }

                await Task.Delay(TimeSpan.FromSeconds(2), cancellationToken);
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                break;
            }
            catch (ObjectDisposedException)
            {
                break;
            }
            catch (Exception ex)
            {
                _logger.LogDebug(ex, "UDP fallback advertising tick failed.");
                await Task.Delay(TimeSpan.FromSeconds(2), cancellationToken);
            }
        }
    }

    private async Task RunFallbackDiscoveryAsync(UdpClient client, CancellationToken cancellationToken)
    {
        while (!cancellationToken.IsCancellationRequested)
        {
            try
            {
                var result = await client.ReceiveAsync(cancellationToken);
                HandleFallbackDiscoveryPacket(result.Buffer, result.RemoteEndPoint);
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                break;
            }
            catch (ObjectDisposedException)
            {
                break;
            }
            catch (Exception ex)
            {
                _logger.LogDebug(ex, "UDP fallback discovery receive failed.");
            }
        }
    }

    private void HandleFallbackDiscoveryPacket(byte[] buffer, IPEndPoint remoteEndPoint)
    {
        try
        {
            using var document = JsonDocument.Parse(buffer);
            var root = document.RootElement;
            if (!root.TryGetProperty("kind", out var kindElement) ||
                !string.Equals(kindElement.GetString(), "fallback-discovery", StringComparison.Ordinal))
            {
                return;
            }

            var instanceName = root.TryGetProperty("instanceId", out var instanceElement)
                ? instanceElement.GetString()
                : null;
            var deviceIdHint = root.TryGetProperty("did", out var didElement) && didElement.ValueKind == JsonValueKind.String
                ? didElement.GetString()
                : instanceName;
            if (string.IsNullOrWhiteSpace(instanceName) || string.IsNullOrWhiteSpace(deviceIdHint))
            {
                return;
            }

            if (_profile != null && string.Equals(instanceName, _profile.InstanceName.ToString(), StringComparison.Ordinal))
            {
                return;
            }

            if (!string.IsNullOrWhiteSpace(_advertisedDeviceId) &&
                string.Equals(deviceIdHint, _advertisedDeviceId, StringComparison.Ordinal))
            {
                return;
            }

            var port = root.TryGetProperty("port", out var portElement) && portElement.TryGetInt32(out var parsedPort)
                ? parsedPort
                : RiftNetworkDefaults.DefaultPort;
            var txtRecord = new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["minV"] = root.TryGetProperty("minV", out var minElement) ? minElement.GetString() ?? "0.1-draft" : "0.1-draft",
                ["maxV"] = root.TryGetProperty("maxV", out var maxElement) ? maxElement.GetString() ?? "0.1-draft" : "0.1-draft",
                ["did"] = deviceIdHint
            };
            if (root.TryGetProperty("fp", out var fpElement) && fpElement.ValueKind == JsonValueKind.String)
            {
                var fp = fpElement.GetString();
                if (!string.IsNullOrWhiteSpace(fp))
                {
                    txtRecord["fp"] = fp!;
                }
            }

            var peerInfo = new PeerDiscoveredEventArgs(
                deviceIdHint,
                instanceName!,
                remoteEndPoint.Address.ToString(),
                port,
                txtRecord.GetValueOrDefault("minV"),
                txtRecord.GetValueOrDefault("maxV"),
                txtRecord,
                remoteEndPoint,
                observedAddresses: [remoteEndPoint.Address.ToString()]);

            _fallbackPingPongTargets[remoteEndPoint.Address] = DateTimeOffset.UtcNow;
            PublishPeer(peerInfo, "UDP fallback");
        }
        catch (Exception ex)
        {
            _logger.LogDebug(ex, "Ignoring malformed UDP fallback discovery packet from {RemoteEndPoint}.", remoteEndPoint);
        }
    }

    private PeerDiscoveredEventArgs CreatePeerDiscoveredEventArgs(ServiceInstanceDiscoveryEventArgs e)
    {
        var records = e.Message.Answers.Concat(e.Message.AdditionalRecords).ToArray();

        var serviceInstanceName = e.ServiceInstanceName;
        var srvRecord = records
            .OfType<SRVRecord>()
            .FirstOrDefault(record => record.Name == serviceInstanceName);

        if (srvRecord is null)
        {
            throw new InvalidOperationException($"[mDNS Debug] Discovered service instance '{serviceInstanceName}' did not include an SRV record. Found records: {string.Join(", ", records.Select(r => r.GetType().Name))}");
        }

        var txtRecord = records
            .OfType<TXTRecord>()
            .FirstOrDefault(record => record.Name == serviceInstanceName);

        if (txtRecord is null)
        {
            _logger.LogWarning("[mDNS Debug] TXT record is completely missing for {InstanceName}", serviceInstanceName);
        }

        var txtProperties = ParseTxtProperties(txtRecord);
        var discoveredAddresses = records
            .OfType<AddressRecord>()
            .Where(record => record.Name == srvRecord.Target)
            .Select(record => record.Address.ToString())
            .Where(address => !string.IsNullOrWhiteSpace(address))
            .Distinct(StringComparer.Ordinal)
            .ToList();
        var remoteAddress = e.RemoteEndPoint?.Address.ToString();
        if (!string.IsNullOrWhiteSpace(remoteAddress) && !discoveredAddresses.Contains(remoteAddress, StringComparer.Ordinal))
        {
            discoveredAddresses.Add(remoteAddress);
        }

        var host = discoveredAddresses.FirstOrDefault() ?? srvRecord.Target.ToString();
        var port = srvRecord.Port;

        var deviceIdHint = txtProperties.GetValueOrDefault("did");
        _logger.LogDebug("[mDNS Debug] Parsed TXT record. DeviceIdHint: '{DeviceIdHint}'", deviceIdHint);
        foreach (var kvp in txtProperties)
        {
            _logger.LogDebug("[mDNS Debug] TXT: {Key} = {Value}", kvp.Key, kvp.Value);
        }

        return new PeerDiscoveredEventArgs(
            deviceIdHint: deviceIdHint,
            instanceName: serviceInstanceName.ToString(),
            host: host,
            port: port,
            minVersion: txtProperties.GetValueOrDefault("minV"),
            maxVersion: txtProperties.GetValueOrDefault("maxV"),
            txtRecord: txtProperties,
            remoteEndPoint: e.RemoteEndPoint,
            observedAddresses: discoveredAddresses);
    }

    private void PublishPeer(PeerDiscoveredEventArgs peerInfo, string source)
    {
        if (!_announcementGate.ShouldPublish(peerInfo))
        {
            return;
        }

        _logger.LogInformation(
            "Discovered Rift peer via {Source}: {DeviceId} at {Host}:{Port}",
            source,
            peerInfo.DeviceIdHint ?? peerInfo.InstanceName,
            peerInfo.Host,
            peerInfo.Port);
        PeerDiscovered?.Invoke(this, peerInfo);
    }

    private static Dictionary<string, string> ParseTxtProperties(TXTRecord? txtRecord)
    {
        var properties = new Dictionary<string, string>(StringComparer.Ordinal);
        if (txtRecord is null)
        {
            return properties;
        }

        foreach (var entry in txtRecord.Strings)
        {
            var separatorIndex = entry.IndexOf('=');
            if (separatorIndex <= 0)
            {
                continue;
            }

            var key = entry[..separatorIndex];
            var value = entry[(separatorIndex + 1)..];
            properties[key] = value;
        }

        return properties;
    }

    public void Dispose()
    {
        lock (_syncRoot)
        {
            _isAdvertising = false;
            _isDiscovering = false;
            _shutdownCts.Cancel();
            _networkRefreshDebounceTimer?.Dispose();
            _networkRefreshDebounceTimer = null;
            _fallbackAdvertiser?.Dispose();
            _fallbackAdvertiser = null;
            _fallbackDiscoveryListener?.Dispose();
            _fallbackDiscoveryListener = null;
            if (_isMdnsRunning)
            {
                _mdns.Stop();
                _isMdnsRunning = false;
            }
            _serviceDiscovery.Dispose();
            _mdns.Dispose();
            _shutdownCts.Dispose();
            if (_subscribedToNetworkChanges)
            {
                NetworkChange.NetworkAddressChanged -= OnNetworkAddressChanged;
                NetworkChange.NetworkAvailabilityChanged -= OnNetworkAvailabilityChanged;
            }
        }
    }

    private IReadOnlyList<FallbackBroadcastTarget> GetFallbackBroadcastTargets()
    {
        lock (_syncRoot)
        {
            return _fallbackBroadcastTargets;
        }
    }

    private void RefreshFallbackBroadcastTargets(bool force = false)
    {
        lock (_syncRoot)
        {
            if (!force &&
                _fallbackBroadcastTargets.Count > 0 &&
                DateTimeOffset.UtcNow - _fallbackBroadcastTargetsRefreshedAt < TimeSpan.FromSeconds(30))
            {
                return;
            }

            _fallbackBroadcastTargets = FallbackNetworkInterfaceEnumerator.EnumerateIPv4BroadcastTargets();
            _fallbackBroadcastTargetsRefreshedAt = DateTimeOffset.UtcNow;
        }
    }

    internal static bool ShouldSubscribeToNetworkChanges(bool isMacOS) => !isMacOS;

    private void OnNetworkAvailabilityChanged(object? sender, NetworkAvailabilityEventArgs e)
    {
        QueueNetworkRefresh();
    }

    private void OnNetworkAddressChanged(object? sender, EventArgs e)
    {
        QueueNetworkRefresh();
    }

    private void QueueNetworkRefresh()
    {
        if (Interlocked.Exchange(ref _networkRefreshQueued, 1) == 1)
        {
            return;
        }

        lock (_syncRoot)
        {
            _networkRefreshDebounceTimer?.Dispose();
            _networkRefreshDebounceTimer = new Timer(_ =>
            {
                try
                {
                    lock (_syncRoot)
                    {
                        _fallbackBroadcastTargets = [];
                        _fallbackBroadcastTargetsRefreshedAt = DateTimeOffset.MinValue;

                        if (_profile is not null && _isAdvertising)
                        {
                            _serviceDiscovery.Unadvertise(_profile);
                            _serviceDiscovery.Advertise(_profile);
                        }

                        if (_isDiscovering)
                        {
                            _serviceDiscovery.QueryServiceInstances("_rift._tcp");
                        }
                    }
                }
                catch (Exception ex)
                {
                    _logger.LogDebug(ex, "Failed to refresh discovery state after network change.");
                }
                finally
                {
                    Interlocked.Exchange(ref _networkRefreshQueued, 0);
                }
            }, null, TimeSpan.FromSeconds(1), Timeout.InfiniteTimeSpan);
        }
    }
}

internal sealed class DiscoveryAnnouncementGate(
    TimeProvider? timeProvider = null,
    TimeSpan? minimumInterval = null)
{
    private readonly object _syncRoot = new();
    private readonly Dictionary<string, DateTimeOffset> _lastPublished = new(StringComparer.Ordinal);
    private readonly TimeProvider _timeProvider = timeProvider ?? TimeProvider.System;
    private readonly TimeSpan _minimumInterval = minimumInterval ?? TimeSpan.FromSeconds(5);

    public bool ShouldPublish(PeerDiscoveredEventArgs peer)
    {
        var peerId = string.IsNullOrWhiteSpace(peer.DeviceIdHint)
            ? peer.InstanceName
            : peer.DeviceIdHint;
        var key = $"{peerId}|{peer.Host}|{peer.Port}";
        var now = _timeProvider.GetUtcNow();

        lock (_syncRoot)
        {
            if (_lastPublished.TryGetValue(key, out var lastPublished) &&
                now - lastPublished < _minimumInterval)
            {
                return false;
            }

            _lastPublished[key] = now;
            return true;
        }
    }
}
