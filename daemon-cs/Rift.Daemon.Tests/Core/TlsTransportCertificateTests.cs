using Rift.Daemon.Core.Cryptography;
using Rift.Daemon.Core.Networking;
using Xunit;

namespace Rift.Daemon.Tests.Core;

public class TlsTransportCertificateTests
{
    [Fact]
    public void ExtractDeviceIdFromCertificate_MatchesEmbeddedEd25519Identity()
    {
        var identityManager = new IdentityManager();
        identityManager.EnsureIdentityInitialized();

        var cert = identityManager.GetTlsCertificate();
        var expectedDeviceId = identityManager.GetDeviceId();

        var actualDeviceId = TlsTransport.ExtractDeviceIdFromCertificate(cert);

        Assert.Equal(expectedDeviceId, actualDeviceId);
    }
}
