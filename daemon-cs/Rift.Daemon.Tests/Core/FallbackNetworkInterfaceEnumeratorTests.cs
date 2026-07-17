using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using Rift.Daemon.Core.Networking;

namespace Rift.Daemon.Tests.Core;

public sealed class FallbackNetworkInterfaceEnumeratorTests
{
    [Fact]
    public void TryGetIPv4Mask_UsesExplicitMaskWhenPresent()
    {
        var address = new FakeUnicastIPAddressInformation(
            IPAddress.Parse("192.168.10.25"),
            IPAddress.Parse("255.255.240.0"),
            prefixLength: 24);

        var found = FallbackNetworkInterfaceEnumerator.TryGetIPv4Mask(address, out var mask);

        Assert.True(found);
        Assert.Equal("255.255.240.0", mask.ToString());
    }

    [Fact]
    public void TryGetIPv4Mask_FallsBackToPrefixLength()
    {
        var address = new FakeUnicastIPAddressInformation(
            IPAddress.Parse("10.10.10.8"),
            IPAddress.Parse("0.0.0.0"),
            prefixLength: 30);

        var found = FallbackNetworkInterfaceEnumerator.TryGetIPv4Mask(address, out var mask);

        Assert.True(found);
        Assert.Equal("255.255.255.252", mask.ToString());
    }

    [Fact]
    public void TryCreateTarget_ComputesBroadcastUsingActualMask()
    {
        var address = new FakeUnicastIPAddressInformation(
            IPAddress.Parse("192.168.10.25"),
            IPAddress.Parse("255.255.240.0"),
            prefixLength: 20);

        var found = FallbackNetworkInterfaceEnumerator.TryCreateTarget("wifi0", address, out var target);

        Assert.True(found);
        Assert.Equal("192.168.15.255", target.BroadcastAddress.ToString());
    }

    [Fact]
    public void TryCreateTarget_RejectsApipaAddress()
    {
        var address = new FakeUnicastIPAddressInformation(
            IPAddress.Parse("169.254.10.25"),
            IPAddress.Parse("255.255.0.0"),
            prefixLength: 16);

        var found = FallbackNetworkInterfaceEnumerator.TryCreateTarget("wifi0", address, out _);

        Assert.False(found);
    }

    private sealed class FakeUnicastIPAddressInformation(
        IPAddress address,
        IPAddress ipv4Mask,
        int prefixLength) : UnicastIPAddressInformation
    {
        public override IPAddress Address => address;
        public override IPAddress IPv4Mask => ipv4Mask;
        public override int PrefixLength => prefixLength;
        public override bool IsDnsEligible => true;
        public override bool IsTransient => false;
        public override long AddressPreferredLifetime => 0;
        public override long AddressValidLifetime => 0;
        public override long DhcpLeaseLifetime => 0;
        public override DuplicateAddressDetectionState DuplicateAddressDetectionState => DuplicateAddressDetectionState.Preferred;
        public override PrefixOrigin PrefixOrigin => PrefixOrigin.Manual;
        public override SuffixOrigin SuffixOrigin => SuffixOrigin.Manual;
    }
}
