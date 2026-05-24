namespace Rift.Daemon.Windows.Interfaces;

public interface IClipboardService
{
    Task OfferAsync(string content);
    Task<string> FetchRequestAsync(string offerId);
}
