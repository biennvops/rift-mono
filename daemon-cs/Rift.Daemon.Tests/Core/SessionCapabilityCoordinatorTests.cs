using Rift.Daemon.Core.Networking;

namespace Rift.Daemon.Tests.Core;

public sealed class SessionCapabilityCoordinatorTests
{
    [Fact]
    public void ComputeSelectedCapabilities_UsesIntersectionWithMinimumVersion()
    {
        var local = new[]
        {
            new CapabilityDescriptor("clipboard.offer_fetch", 2),
            new CapabilityDescriptor("presence.basic", 1),
            new CapabilityDescriptor("security.event_log", 1)
        };
        var remote = new[]
        {
            new CapabilityDescriptor("clipboard.offer_fetch", 1),
            new CapabilityDescriptor("presence.basic", 3),
            new CapabilityDescriptor("operation.lifecycle", 1)
        };

        var selected = SessionCapabilityCoordinator.ComputeSelectedCapabilities(local, remote);

        Assert.Collection(
            selected,
            capability =>
            {
                Assert.Equal("clipboard.offer_fetch", capability.Name);
                Assert.Equal(1, capability.Version);
            },
            capability =>
            {
                Assert.Equal("presence.basic", capability.Name);
                Assert.Equal(1, capability.Version);
            });
    }

    [Fact]
    public void ValidateSelectedCapabilities_AcceptsExactComputedIntersection()
    {
        var local = new[]
        {
            new CapabilityDescriptor("clipboard.offer_fetch", 1),
            new CapabilityDescriptor("presence.basic", 1)
        };
        var remote = new[]
        {
            new CapabilityDescriptor("clipboard.offer_fetch", 2),
            new CapabilityDescriptor("presence.basic", 1)
        };
        var selected = new[]
        {
            new CapabilityDescriptor("clipboard.offer_fetch", 1),
            new CapabilityDescriptor("presence.basic", 1)
        };

        Assert.True(SessionCapabilityCoordinator.ValidateSelectedCapabilities(local, remote, selected));
    }

    [Fact]
    public void ValidateSelectedCapabilities_RejectsUnexpectedCapability()
    {
        var local = new[]
        {
            new CapabilityDescriptor("clipboard.offer_fetch", 1)
        };
        var remote = new[]
        {
            new CapabilityDescriptor("clipboard.offer_fetch", 1)
        };
        var selected = new[]
        {
            new CapabilityDescriptor("clipboard.offer_fetch", 1),
            new CapabilityDescriptor("presence.basic", 1)
        };

        Assert.False(SessionCapabilityCoordinator.ValidateSelectedCapabilities(local, remote, selected));
    }
}
