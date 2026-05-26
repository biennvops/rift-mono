using Xunit;

namespace Rift.Daemon.Windows.Tests;

public class ConformanceTests
{
    [Fact]
    public void Identity_Matches_Vector()
    {
        // Placeholder test. To be implemented when vectors and IdentityManager are ready.
        // It will load ed25519_identity.json and verify keys.
        Assert.True(true);
    }

    [Fact]
    public void Fingerprint_Matches_Vector()
    {
        // Placeholder test. To be implemented when vectors and Fingerprint logic are ready.
        // It will load fingerprints.json and verify string derivation.
        Assert.True(true);
    }
}
