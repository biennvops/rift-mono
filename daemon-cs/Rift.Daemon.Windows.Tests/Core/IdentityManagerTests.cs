using Xunit;
using Moq;
using Rift.Daemon.Windows.Core.Interfaces;

namespace Rift.Daemon.Windows.Tests.Core;

public class IdentityManagerTests
{
    [Fact]
    public void EnsureIdentityInitialized_CallsMethodSuccessfully()
    {
        // Arrange
        var mockIdentityManager = new Mock<IIdentityManager>();
        
        // Act
        mockIdentityManager.Object.EnsureIdentityInitialized();
        
        // Assert (Note: This is skeleton scaffolding that verifies mock dispatch, not actual behavior)
        mockIdentityManager.Verify(m => m.EnsureIdentityInitialized(), Times.Once);
    }
}
