using System.Threading.Tasks;

namespace Rift.Daemon.Windows.Core.Interfaces;

public interface IClipboardService
{
    /// <summary>
    /// Broadcasts a newly copied clipboard item offer metadata to trusted peers.
    /// </summary>
    Task BroadcastOfferAsync(string offerId, string contentType, long size, string hash, long expiresInMs, string requiredCapability, long offerSequence);

    /// <summary>
    /// Handles a received clipboard offer from a trusted peer.
    /// </summary>
    Task HandleOfferReceivedAsync(string deviceId, string offerId, string contentType, long size, string hash, long expiresInMs, long offerSequence);

    /// <summary>
    /// Explicitly fetches the content of an offer from a peer.
    /// </summary>
    Task<byte[]> FetchContentAsync(string deviceId, string offerId);
}
