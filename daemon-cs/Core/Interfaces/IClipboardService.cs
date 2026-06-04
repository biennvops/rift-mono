using System.Threading.Tasks;

namespace Rift.Daemon.Windows.Core.Interfaces;

public interface IClipboardService
{
    /// <summary>
    /// Broadcasts a newly copied clipboard item offer metadata to trusted peers.
    /// </summary>
    Task BroadcastOfferAsync(string contentType, long size, string hash);

    /// <summary>
    /// Handles a received clipboard offer from a trusted peer.
    /// </summary>
    Task HandleOfferReceivedAsync(string deviceId, string contentType, long size, string hash);

    /// <summary>
    /// Explicitly fetches the content of an offer from a peer.
    /// </summary>
    Task<string> FetchContentAsync(string deviceId, string hash);
}
