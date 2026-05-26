using Rift.Daemon.Windows.Interfaces;

namespace Rift.Daemon.Windows.Services.Mocks;

public class MockIdentityManager : IIdentityManager
{
    public ReadOnlySpan<byte> GetPublicKey() => ReadOnlySpan<byte>.Empty;
    public ReadOnlySpan<byte> GetCertificate() => ReadOnlySpan<byte>.Empty;
    public Task EnsureIdentityAsync() => Task.CompletedTask;
}

public class MockTrustStore : ITrustStore
{
    public Task<PeerTrustState?> GetTrustStateAsync(string deviceId) => Task.FromResult<PeerTrustState?>(PeerTrustState.Discovered);
    public Task UpdateTrustAsync(string deviceId, PeerTrustState state) => Task.CompletedTask;
}

public class MockDiscoveryService : IDiscoveryService
{
    public void StartAdvertising() { }
    public void StartBrowsing() { }
}

public class MockClipboardService : IClipboardService
{
    public Task OfferAsync(string content) => Task.CompletedTask;
    public Task<string> FetchRequestAsync(string offerId) => Task.FromResult(string.Empty);
}
