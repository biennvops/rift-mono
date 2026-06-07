using System.Threading.Tasks;

namespace Rift.Daemon.Core.Interfaces;

public interface IClipboardService
{
    Task BroadcastOfferAsync(string offerId, string contentType, long size, string hash, long expiresInMs, string requiredCapability, long offerSequence);

    Task HandleOfferReceivedAsync(string deviceId, string offerId, string contentType, long size, string hash, long expiresInMs, long offerSequence);

    Task<byte[]> FetchContentAsync(string deviceId, string offerId);
}
