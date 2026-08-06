using System.Diagnostics;
using System.Globalization;
using System.Text;
using System.Text.Json;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;
using Rift.Daemon.Core.Interfaces;

namespace Rift.Daemon.Core;

public sealed class DeviceStatusService : IDeviceStatusService
{
    private const string RequiredCapability = "device.status";
    private static readonly TimeSpan StaleAfter = TimeSpan.FromMinutes(30);
    private static readonly HashSet<string> ChargingStates = new(StringComparer.Ordinal)
    {
        "charging",
        "discharging",
        "full",
        "notCharging",
        "unknown"
    };
    private static readonly HashSet<string> PowerSources = new(StringComparer.Ordinal)
    {
        "battery",
        "ac",
        "usb",
        "unknown"
    };

    private readonly Lock _gate = new();
    private readonly Dictionary<string, CachedStatus> _statuses = new(StringComparer.Ordinal);
    private readonly ITransport _transport;
    private readonly IPresenceService _presenceService;
    private readonly IIdentityManager _identityManager;
    private readonly IIpcNotificationService? _ipcNotificationService;
    private readonly ILogger<DeviceStatusService> _logger;

    public DeviceStatusService(
        ITransport transport,
        IPresenceService presenceService,
        IIdentityManager identityManager,
        IIpcNotificationService? ipcNotificationService = null,
        ILogger<DeviceStatusService>? logger = null)
    {
        _transport = transport;
        _presenceService = presenceService;
        _identityManager = identityManager;
        _ipcNotificationService = ipcNotificationService;
        _logger = logger ?? NullLogger<DeviceStatusService>.Instance;
        _transport.SessionStateChanged += OnSessionStateChanged;
    }

    public async Task<NotifyLocalDeviceStatusResult> UpdateLocalStatusAsync(
        DeviceStatusRecord status,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var normalized = Normalize(status, _identityManager.GetDeviceId());
        Validate(normalized);
        Cache(normalized);
        await NotifyIpcAsync(normalized, cancellationToken).ConfigureAwait(false);

        var broadcastTo = new List<string>();
        foreach (var peer in _presenceService.ListPeers())
        {
            if (!string.Equals(peer.Status, "online", StringComparison.Ordinal) ||
                !peer.Capabilities.Contains(RequiredCapability, StringComparer.Ordinal) ||
                !_transport.HasProtectedSession(peer.DeviceId))
            {
                continue;
            }

            await SendStatusAsync(peer.DeviceId, normalized, cancellationToken).ConfigureAwait(false);
            broadcastTo.Add(peer.DeviceId);
        }

        return new NotifyLocalDeviceStatusResult { BroadcastTo = broadcastTo };
    }

    public async Task HandlePeerStatusUpdatedAsync(
        DeviceStatusRecord status,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        Validate(status);
        Cache(status);
        await NotifyIpcAsync(status, cancellationToken).ConfigureAwait(false);
    }

    public DeviceStatusRecord? GetDeviceStatus(string sourceDeviceId)
    {
        if (string.IsNullOrWhiteSpace(sourceDeviceId))
        {
            return null;
        }

        lock (_gate)
        {
            if (!_statuses.TryGetValue(sourceDeviceId, out var cached))
            {
                return null;
            }

            var presence = _presenceService.GetPeerPresence(sourceDeviceId);
            var isStale = presence is not null && !string.Equals(presence.Status, "online", StringComparison.Ordinal)
                || Stopwatch.GetElapsedTime(cached.ReceivedTimestamp) >= StaleAfter;
            return Clone(cached.Status, isStale);
        }
    }

    private void OnSessionStateChanged(object? sender, SessionStateChangedEventArgs args)
    {
        if (!args.IsOnline || !args.SelectedCapabilities.Contains(RequiredCapability, StringComparer.Ordinal))
        {
            return;
        }

        DeviceStatusRecord? localStatus;
        lock (_gate)
        {
            _statuses.TryGetValue(_identityManager.GetDeviceId(), out var cached);
            localStatus = cached?.Status;
        }

        if (localStatus is not null)
        {
            _ = ReplayStatusAsync(args.PeerDeviceId, localStatus);
        }
    }

    private async Task ReplayStatusAsync(string peerDeviceId, DeviceStatusRecord status)
    {
        try
        {
            await SendStatusAsync(peerDeviceId, status, CancellationToken.None).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            _logger.LogDebug(ex, "Failed to replay device status to {PeerDeviceId}.", peerDeviceId);
        }
    }

    private async Task SendStatusAsync(
        string peerDeviceId,
        DeviceStatusRecord status,
        CancellationToken cancellationToken)
    {
        var envelope = new
        {
            rift = "0.1-draft",
            type = "device.statusUpdated",
            messageId = Guid.NewGuid().ToString("D"),
            sourceDeviceId = status.SourceDeviceId,
            destinationDeviceId = peerDeviceId,
            payload = CreatePayload(status)
        };
        await _transport.SendAsync(
            peerDeviceId,
            Encoding.UTF8.GetBytes(JsonSerializer.Serialize(envelope)),
            cancellationToken).ConfigureAwait(false);
    }

    private async Task NotifyIpcAsync(DeviceStatusRecord status, CancellationToken cancellationToken)
    {
        if (_ipcNotificationService is null)
        {
            return;
        }

        await _ipcNotificationService.NotifyAsync(
            "rift.onDeviceStatusUpdated",
            Clone(status, false),
            cancellationToken).ConfigureAwait(false);
    }

    private void Cache(DeviceStatusRecord status)
    {
        lock (_gate)
        {
            _statuses[status.SourceDeviceId] = new CachedStatus(Clone(status, false), Stopwatch.GetTimestamp());
        }
    }

    private static DeviceStatusRecord Normalize(DeviceStatusRecord status, string localDeviceId) => new()
    {
        SourceDeviceId = localDeviceId,
        SourcePlatform = status.SourcePlatform,
        BatteryPercent = status.BatteryPercent,
        ChargingState = status.ChargingState,
        PowerSource = status.PowerSource,
        LowPowerMode = status.LowPowerMode,
        ObservedAt = string.IsNullOrWhiteSpace(status.ObservedAt)
            ? DateTimeOffset.UtcNow.ToString("O")
            : status.ObservedAt
    };

    private static void Validate(DeviceStatusRecord status)
    {
        if (string.IsNullOrWhiteSpace(status.SourceDeviceId))
        {
            throw new ArgumentException("Device status requires sourceDeviceId.");
        }
        if (status.BatteryPercent is < 0 or > 100)
        {
            throw new ArgumentException("batteryPercent must be between 0 and 100.");
        }
        if (status.ChargingState is not null && !ChargingStates.Contains(status.ChargingState))
        {
            throw new ArgumentException("chargingState is not supported.");
        }
        if (status.PowerSource is not null && !PowerSources.Contains(status.PowerSource))
        {
            throw new ArgumentException("powerSource is not supported.");
        }
        if (status.BatteryPercent is null && status.ChargingState is null && status.PowerSource is null && status.LowPowerMode is null)
        {
            throw new ArgumentException("Device status requires at least one power-state field.");
        }
        if (!DateTimeOffset.TryParse(
                status.ObservedAt,
                CultureInfo.InvariantCulture,
                DateTimeStyles.RoundtripKind,
                out var observedAt) ||
            observedAt.Offset != TimeSpan.Zero ||
            !(status.ObservedAt.EndsWith('Z') || status.ObservedAt.EndsWith("+00:00", StringComparison.Ordinal)))
        {
            throw new ArgumentException("observedAt must be an RFC 3339 UTC timestamp.");
        }
    }

    private static IReadOnlyDictionary<string, object?> CreatePayload(DeviceStatusRecord status)
    {
        var payload = new Dictionary<string, object?>(StringComparer.Ordinal)
        {
            ["sourceDeviceId"] = status.SourceDeviceId,
            ["observedAt"] = status.ObservedAt
        };
        if (status.SourcePlatform is not null)
        {
            payload["sourcePlatform"] = status.SourcePlatform;
        }
        if (status.BatteryPercent.HasValue)
        {
            payload["batteryPercent"] = status.BatteryPercent.Value;
        }
        if (status.ChargingState is not null)
        {
            payload["chargingState"] = status.ChargingState;
        }
        if (status.PowerSource is not null)
        {
            payload["powerSource"] = status.PowerSource;
        }
        if (status.LowPowerMode.HasValue)
        {
            payload["lowPowerMode"] = status.LowPowerMode.Value;
        }
        return payload;
    }

    private static DeviceStatusRecord Clone(DeviceStatusRecord status, bool isStale) => new()
    {
        SourceDeviceId = status.SourceDeviceId,
        SourcePlatform = status.SourcePlatform,
        BatteryPercent = status.BatteryPercent,
        ChargingState = status.ChargingState,
        PowerSource = status.PowerSource,
        LowPowerMode = status.LowPowerMode,
        ObservedAt = status.ObservedAt,
        IsStale = isStale
    };

    private sealed record CachedStatus(DeviceStatusRecord Status, long ReceivedTimestamp);
}
