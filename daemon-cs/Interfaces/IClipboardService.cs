using Rift.Daemon.Windows.Models;

namespace Rift.Daemon.Windows.Interfaces;

public interface IClipboardService
{
    Task<ClipboardOffer> OfferAsync(string content);
    Task<string> FetchRequestAsync(string offerId);
}
