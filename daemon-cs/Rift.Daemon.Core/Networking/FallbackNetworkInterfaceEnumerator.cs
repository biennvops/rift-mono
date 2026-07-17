using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;

namespace Rift.Daemon.Core.Networking;

internal sealed record FallbackBroadcastTarget(
    string InterfaceId,
    IPAddress UnicastAddress,
    IPAddress BroadcastAddress);

internal static class FallbackNetworkInterfaceEnumerator
{
    public static IReadOnlyList<FallbackBroadcastTarget> EnumerateIPv4BroadcastTargets()
    {
        var results = new List<FallbackBroadcastTarget>();
        var seen = new HashSet<string>(StringComparer.Ordinal);

        foreach (var networkInterface in NetworkInterface.GetAllNetworkInterfaces())
        {
            if (!IsEligibleInterface(networkInterface))
            {
                continue;
            }

            IPInterfaceProperties properties;
            try
            {
                properties = networkInterface.GetIPProperties();
            }
            catch
            {
                continue;
            }

            foreach (var unicastAddress in properties.UnicastAddresses)
            {
                if (!TryCreateTarget(networkInterface.Id, unicastAddress, out var target))
                {
                    continue;
                }

                var key = $"{target.InterfaceId}|{target.UnicastAddress}|{target.BroadcastAddress}";
                if (seen.Add(key))
                {
                    results.Add(target);
                }
            }
        }

        return results;
    }

    internal static bool TryCreateTarget(
        string interfaceId,
        UnicastIPAddressInformation unicastAddress,
        out FallbackBroadcastTarget target)
    {
        target = null!;

        if (unicastAddress.Address.AddressFamily != AddressFamily.InterNetwork)
        {
            return false;
        }

        if (IPAddress.IsLoopback(unicastAddress.Address) || IsApipa(unicastAddress.Address))
        {
            return false;
        }

        if (!TryGetIPv4Mask(unicastAddress, out var mask))
        {
            return false;
        }

        var addressBytes = unicastAddress.Address.GetAddressBytes();
        var maskBytes = mask.GetAddressBytes();
        if (addressBytes.Length != 4 || maskBytes.Length != 4)
        {
            return false;
        }

        var broadcastBytes = new byte[4];
        for (var i = 0; i < 4; i += 1)
        {
            broadcastBytes[i] = (byte)(addressBytes[i] | ~maskBytes[i]);
        }

        target = new FallbackBroadcastTarget(
            interfaceId,
            unicastAddress.Address,
            new IPAddress(broadcastBytes));
        return true;
    }

    internal static bool TryGetIPv4Mask(UnicastIPAddressInformation unicastAddress, out IPAddress mask)
    {
        mask = IPAddress.None;

        if (unicastAddress.IPv4Mask is { } ipv4Mask &&
            ipv4Mask.AddressFamily == AddressFamily.InterNetwork &&
            ipv4Mask.GetAddressBytes().Any(b => b != 0))
        {
            mask = ipv4Mask;
            return true;
        }

        var prefixLength = unicastAddress.PrefixLength;
        if (prefixLength is < 0 or > 32)
        {
            return false;
        }

        var maskBytes = new byte[4];
        for (var i = 0; i < prefixLength; i += 1)
        {
            maskBytes[i / 8] |= (byte)(1 << (7 - (i % 8)));
        }

        mask = new IPAddress(maskBytes);
        return prefixLength > 0;
    }

    private static bool IsEligibleInterface(NetworkInterface networkInterface)
    {
        if (networkInterface.OperationalStatus != OperationalStatus.Up)
        {
            return false;
        }

        if (!networkInterface.Supports(NetworkInterfaceComponent.IPv4))
        {
            return false;
        }

        return networkInterface.NetworkInterfaceType is not (
            NetworkInterfaceType.Loopback or
            NetworkInterfaceType.Tunnel or
            NetworkInterfaceType.Unknown);
    }

    private static bool IsApipa(IPAddress address)
    {
        var bytes = address.GetAddressBytes();
        return bytes is [169, 254, _, _];
    }
}
