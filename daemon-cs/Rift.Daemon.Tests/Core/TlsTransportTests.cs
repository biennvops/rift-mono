using System.Text;
using Rift.Daemon.Core.Networking;
using Rift.Daemon.Core.Protocol;
using Xunit;

namespace Rift.Daemon.Tests.Core;

public class TlsTransportTests
{
    [Fact]
    public void GetMaxInboundFrameSize_UsesPreAuthLimitUntilAuthenticated()
    {
        Assert.Equal(RiftFrame.MaxPreAuthSize, TlsTransport.GetMaxInboundFrameSize(isAuthenticated: false));
        Assert.Equal(RiftFrame.MaxPostAuthSize, TlsTransport.GetMaxInboundFrameSize(isAuthenticated: true));
    }

    [Fact]
    public void GetMaxOutboundFrameSize_UsesPreAuthLimitUntilAuthenticated()
    {
        Assert.Equal(RiftFrame.MaxPreAuthSize, TlsTransport.GetMaxOutboundFrameSize(isAuthenticated: false));
        Assert.Equal(RiftFrame.MaxPostAuthSize, TlsTransport.GetMaxOutboundFrameSize(isAuthenticated: true));
    }

    [Fact]
    public void ShouldPromoteAuthenticationState_ReturnsTrueForSessionAccept()
    {
        var payload = Encoding.UTF8.GetBytes("{\"type\":\"session.accept\"}");

        Assert.True(TlsTransport.ShouldPromoteAuthenticationState(payload));
    }

    [Fact]
    public void ShouldPromoteAuthenticationState_ReturnsTrueForCapabilityAdvertise()
    {
        var payload = Encoding.UTF8.GetBytes("{\"type\":\"capability.advertise\"}");

        Assert.True(TlsTransport.ShouldPromoteAuthenticationState(payload));
    }

    [Fact]
    public void ShouldPromoteAuthenticationState_ReturnsFalseForSessionHello()
    {
        var payload = Encoding.UTF8.GetBytes("{\"type\":\"session.hello\"}");

        Assert.False(TlsTransport.ShouldPromoteAuthenticationState(payload));
    }

    [Fact]
    public void ShouldPromoteAuthenticationState_ReturnsFalseForMalformedJson()
    {
        var payload = Encoding.UTF8.GetBytes("not-json");

        Assert.False(TlsTransport.ShouldPromoteAuthenticationState(payload));
    }
}
