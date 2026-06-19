using Rift.Daemon.Core;

namespace Rift.Daemon.Tests.Core;

public sealed class PresenceServiceTests
{
    [Fact]
    public void MarkPeerOffline_PreservesTrackedPeerAndUpdatesStatus()
    {
        var service = new PresenceService();
        service.UpdatePeerPresence("rift-peer", "online", "2026-06-18T12:00:00Z", ["presence.basic"]);

        service.MarkPeerOffline("rift-peer");

        var presence = service.GetPeerPresence("rift-peer");
        Assert.NotNull(presence);
        Assert.Equal("offline", presence!.Status);
        Assert.Contains("presence.basic", presence.Capabilities);
    }
}
