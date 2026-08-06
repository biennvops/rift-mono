namespace Rift.Daemon.Core.Interfaces;

public sealed class DeviceStatusRecord
{
    public string SourceDeviceId { get; init; } = string.Empty;
    public string? SourcePlatform { get; init; }
    public bool? BatteryPresent { get; init; }
    public int? BatteryPercent { get; init; }
    public string? ChargingState { get; init; }
    public string? PowerSource { get; init; }
    public bool? LowPowerMode { get; init; }
    public string ObservedAt { get; init; } = string.Empty;
    public bool IsStale { get; init; }
}

public sealed class NotifyLocalDeviceStatusResult
{
    public IReadOnlyList<string> BroadcastTo { get; init; } = [];
}

public interface IDeviceStatusService
{
    Task<NotifyLocalDeviceStatusResult> UpdateLocalStatusAsync(
        DeviceStatusRecord status,
        CancellationToken cancellationToken);

    Task HandlePeerStatusUpdatedAsync(
        DeviceStatusRecord status,
        CancellationToken cancellationToken);

    Task SendPeerErrorAsync(
        string peerDeviceId,
        string failureReason,
        string? refMessageId,
        string message,
        CancellationToken cancellationToken);

    DeviceStatusRecord? GetDeviceStatus(string sourceDeviceId);
}
