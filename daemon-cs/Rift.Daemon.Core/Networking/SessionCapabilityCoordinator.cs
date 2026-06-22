using System.Text;
using System.Text.Json;
using Rift.Daemon.Core.Protocol;

namespace Rift.Daemon.Core.Networking;

internal sealed class SessionCapabilityCoordinator
{
    private const int MaxCapabilityCount = 64;
    private const int MaxCapabilityNameLength = 128;
    private const int MaxPolicyFlagCount = 16;
    private const int MaxPolicyFlagLength = 128;

    internal static readonly CapabilityDescriptor[] SupportedCapabilities =
    [
        new("clipboard.offer_fetch", 1),
        new("presence.basic", 1),
        new("operation.lifecycle", 1),
        new("security.event_log", 1)
    ];

    private static readonly StringComparer CapabilityNameComparer = StringComparer.Ordinal;
    private static readonly HashSet<string> SupportedCapabilityNames = SupportedCapabilities
        .Select(capability => capability.Name)
        .ToHashSet(CapabilityNameComparer);

    public async Task<IReadOnlyList<CapabilityDescriptor>> NegotiateAsync(
        Stream stream,
        string localDeviceId,
        string remoteDeviceId,
        bool isInitiator,
        Func<Stream, int, CancellationToken, Task<byte[]?>> readFramePayloadAsync,
        CancellationToken cancellationToken)
    {
        await SendCapabilityAdvertiseAsync(stream, localDeviceId, cancellationToken);

        var advertisePayload = await readFramePayloadAsync(stream, RiftFrame.MaxPostAuthSize, cancellationToken)
            ?? throw new InvalidOperationException("Peer closed connection before sending capability.advertise.");
        var remoteAdvertised = ParseAdvertisedCapabilities(advertisePayload, remoteDeviceId);

        if (isInitiator)
        {
            var selected = ComputeSelectedCapabilities(SupportedCapabilities, remoteAdvertised);
            await SendCapabilitySelectedAsync(stream, localDeviceId, selected, cancellationToken);
            return selected;
        }

        var selectedPayload = await readFramePayloadAsync(stream, RiftFrame.MaxPostAuthSize, cancellationToken)
            ?? throw new InvalidOperationException("Peer closed connection before sending capability.selected.");
        var selectedCapabilities = ParseSelectedCapabilities(selectedPayload, remoteDeviceId);

        if (!ValidateSelectedCapabilities(SupportedCapabilities, remoteAdvertised, selectedCapabilities))
        {
            await SendProtocolErrorAsync(stream, localDeviceId, cancellationToken);
            throw new InvalidOperationException("Peer selected capabilities that were not valid for this session.");
        }

        return selectedCapabilities;
    }

    internal static IReadOnlyList<CapabilityDescriptor> ComputeSelectedCapabilities(
        IReadOnlyList<CapabilityDescriptor> localCapabilities,
        IReadOnlyList<CapabilityDescriptor> remoteCapabilities)
    {
        var remoteByName = remoteCapabilities
            .Where(capability => SupportedCapabilityNames.Contains(capability.Name))
            .GroupBy(capability => capability.Name, CapabilityNameComparer)
            .ToDictionary(group => group.Key, group => group.Max(capability => capability.Version), CapabilityNameComparer);

        return localCapabilities
            .Where(capability => SupportedCapabilityNames.Contains(capability.Name))
            .Join(
                remoteByName,
                local => local.Name,
                remote => remote.Key,
                (local, remote) => new CapabilityDescriptor(local.Name, Math.Min(local.Version, remote.Value)))
            .Where(capability => GetMinimumRequiredVersion(capability.Name) <= capability.Version)
            .OrderBy(capability => capability.Name, StringComparer.Ordinal)
            .ToArray();
    }

    internal static bool ValidateSelectedCapabilities(
        IReadOnlyList<CapabilityDescriptor> localCapabilities,
        IReadOnlyList<CapabilityDescriptor> remoteCapabilities,
        IReadOnlyList<CapabilityDescriptor> selectedCapabilities)
    {
        var expected = ComputeSelectedCapabilities(localCapabilities, remoteCapabilities)
            .ToDictionary(capability => capability.Name, capability => capability.Version, StringComparer.Ordinal);

        foreach (var selected in selectedCapabilities)
        {
            if (!expected.TryGetValue(selected.Name, out var expectedVersion) || expectedVersion != selected.Version)
            {
                return false;
            }
        }

        return expected.Count == selectedCapabilities.Count;
    }

    private static async Task SendCapabilityAdvertiseAsync(Stream stream, string localDeviceId, CancellationToken cancellationToken)
    {
        var envelope = new
        {
            rift = "0.1-draft",
            type = "capability.advertise",
            messageId = Guid.NewGuid().ToString("D"),
            sourceDeviceId = localDeviceId,
            payload = new
            {
                capabilities = SupportedCapabilities.Select(capability => new { name = capability.Name, version = capability.Version, policyFlags = Array.Empty<string>() }).ToArray()
            }
        };

        var frame = RiftFrame.Encode(Encoding.UTF8.GetBytes(JsonSerializer.Serialize(envelope)));
        await stream.WriteAsync(frame, cancellationToken);
    }

    private static async Task SendCapabilitySelectedAsync(
        Stream stream,
        string localDeviceId,
        IReadOnlyList<CapabilityDescriptor> selectedCapabilities,
        CancellationToken cancellationToken)
    {
        var envelope = new
        {
            rift = "0.1-draft",
            type = "capability.selected",
            messageId = Guid.NewGuid().ToString("D"),
            sourceDeviceId = localDeviceId,
            payload = new
            {
                selectedCapabilities = selectedCapabilities.Select(capability => new { name = capability.Name, version = capability.Version }).ToArray()
            }
        };

        var frame = RiftFrame.Encode(Encoding.UTF8.GetBytes(JsonSerializer.Serialize(envelope)));
        await stream.WriteAsync(frame, cancellationToken);
    }

    private static async Task SendProtocolErrorAsync(Stream stream, string localDeviceId, CancellationToken cancellationToken)
    {
        var envelope = new
        {
            rift = "0.1-draft",
            type = "error",
            messageId = Guid.NewGuid().ToString("D"),
            sourceDeviceId = localDeviceId,
            payload = new
            {
                failureReason = "ProtocolError"
            }
        };

        var frame = RiftFrame.Encode(Encoding.UTF8.GetBytes(JsonSerializer.Serialize(envelope)));
        await stream.WriteAsync(frame, cancellationToken);
    }

    private static IReadOnlyList<CapabilityDescriptor> ParseAdvertisedCapabilities(byte[] payloadBuffer, string remoteDeviceId)
    {
        using var document = JsonDocument.Parse(payloadBuffer);
        var root = document.RootElement;
        EnsureTypeAndSource(root, "capability.advertise", remoteDeviceId);

        var capabilities = root.GetProperty("payload").GetProperty("capabilities");
        return ParseCapabilities(capabilities);
    }

    private static IReadOnlyList<CapabilityDescriptor> ParseSelectedCapabilities(byte[] payloadBuffer, string remoteDeviceId)
    {
        using var document = JsonDocument.Parse(payloadBuffer);
        var root = document.RootElement;
        EnsureTypeAndSource(root, "capability.selected", remoteDeviceId);

        var capabilities = root.GetProperty("payload").GetProperty("selectedCapabilities");
        return ParseCapabilities(capabilities);
    }

    private static void EnsureTypeAndSource(JsonElement root, string expectedType, string remoteDeviceId)
    {
        var type = root.GetProperty("type").GetString();
        if (!string.Equals(type, expectedType, StringComparison.Ordinal))
        {
            throw new InvalidOperationException($"Expected {expectedType} but received {type ?? "<null>"}.");
        }

        var sourceDeviceId = root.GetProperty("sourceDeviceId").GetString();
        if (!string.Equals(sourceDeviceId, remoteDeviceId, StringComparison.Ordinal))
        {
            throw new InvalidOperationException($"{expectedType} sourceDeviceId did not match the authenticated peer identity.");
        }
    }

    private static IReadOnlyList<CapabilityDescriptor> ParseCapabilities(JsonElement capabilities)
    {
        if (capabilities.ValueKind != JsonValueKind.Array)
        {
            throw new InvalidOperationException("Capability payload must be an array.");
        }

        var parsed = new List<CapabilityDescriptor>();
        foreach (var element in capabilities.EnumerateArray())
        {
            if (parsed.Count >= MaxCapabilityCount)
            {
                throw new InvalidOperationException("Capability advertisement exceeded the maximum capability count.");
            }

            var name = element.GetProperty("name").GetString()
                ?? throw new InvalidOperationException("Capability name was missing.");
            if (name.Length is 0 or > MaxCapabilityNameLength)
            {
                throw new InvalidOperationException("Capability name length exceeded protocol bounds.");
            }

            var version = element.GetProperty("version").GetInt32();
            if (version < 1)
            {
                throw new InvalidOperationException("Capability version must be a positive integer.");
            }

            if (element.TryGetProperty("policyFlags", out var policyFlagsElement))
            {
                ValidatePolicyFlags(policyFlagsElement);
            }

            parsed.Add(new CapabilityDescriptor(name, version));
        }

        return parsed;
    }

    internal static bool HasRequiredCapabilities(IReadOnlyList<CapabilityDescriptor> selectedCapabilities)
    {
        var selectedByName = selectedCapabilities.ToDictionary(capability => capability.Name, capability => capability.Version, CapabilityNameComparer);
        return SupportedCapabilities.All(capability =>
            selectedByName.TryGetValue(capability.Name, out var selectedVersion) &&
            selectedVersion >= GetMinimumRequiredVersion(capability.Name));
    }

    private static int GetMinimumRequiredVersion(string capabilityName)
    {
        return capabilityName switch
        {
            "clipboard.offer_fetch" or "presence.basic" or "operation.lifecycle" or "security.event_log" => 1,
            _ => int.MaxValue
        };
    }

    private static void ValidatePolicyFlags(JsonElement policyFlagsElement)
    {
        if (policyFlagsElement.ValueKind != JsonValueKind.Array)
        {
            throw new InvalidOperationException("Capability policyFlags must be an array.");
        }

        var count = 0;
        foreach (var flagElement in policyFlagsElement.EnumerateArray())
        {
            if (++count > MaxPolicyFlagCount)
            {
                throw new InvalidOperationException("Capability policyFlags exceeded the maximum count.");
            }

            var flag = flagElement.GetString() ?? throw new InvalidOperationException("Capability policy flag was missing.");
            if (flag.Length is 0 or > MaxPolicyFlagLength)
            {
                throw new InvalidOperationException("Capability policy flag length exceeded protocol bounds.");
            }
        }
    }
}

internal sealed record CapabilityDescriptor(string Name, int Version);
