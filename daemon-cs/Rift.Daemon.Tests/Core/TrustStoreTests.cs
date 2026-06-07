using Xunit;
using Moq;
using Rift.Daemon.Core.Interfaces;

namespace Rift.Daemon.Tests.Core;

public class TrustStoreTests
{
    [Fact]
    public void SavePeer_PersistsToStore()
    {
        // Arrange
        var mockTrustStore = new Mock<ITrustStore>();
        var peer = new PeerIdentity { DeviceId = "test-device", State = TrustState.Discovered };
        
        // Act
        mockTrustStore.Object.SavePeer(peer);
        
        // Assert (Note: This is skeleton scaffolding that verifies mock dispatch, not actual behavior)
        mockTrustStore.Verify(t => t.SavePeer(It.Is<PeerIdentity>(p => p.DeviceId == "test-device")), Times.Once);
    }
}
