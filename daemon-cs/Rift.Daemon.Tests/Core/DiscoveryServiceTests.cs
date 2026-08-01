using Rift.Daemon.Core.Networking;

namespace Rift.Daemon.Tests.Core;

public sealed class DiscoveryServiceTests
{
    [Theory]
    [InlineData(true, false)]
    [InlineData(false, true)]
    public void NetworkChangeSubscription_AvoidsMacOSRuntimeCrash(
        bool isMacOS,
        bool expected)
    {
        Assert.Equal(expected, DiscoveryService.ShouldSubscribeToNetworkChanges(isMacOS));
    }
}
