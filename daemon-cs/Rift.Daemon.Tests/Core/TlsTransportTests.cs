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
}
