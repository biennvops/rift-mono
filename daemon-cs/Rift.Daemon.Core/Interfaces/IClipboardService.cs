using System.Threading.Tasks;

namespace Rift.Daemon.Core.Interfaces;

public sealed class ClipboardFailureException(string failureReason, int errorCode, string message) : Exception(message)
{
    public string FailureReason { get; } = failureReason;

    public int ErrorCode { get; } = errorCode;
}

public sealed class ClipboardOfferInfo
{
    public string OfferId { get; init; } = string.Empty;
    public string SourceDeviceId { get; init; } = string.Empty;
    public string ContentType { get; init; } = string.Empty;
    public long ByteSize { get; init; }
    public string Sha256 { get; init; } = string.Empty;
    public string ExpiresAt { get; init; } = string.Empty;
}

public sealed class NotifyClipboardChangeResult
{
    public string OfferId { get; init; } = string.Empty;
    public int ExpiresInMs { get; init; }
    public IReadOnlyList<string> BroadcastTo { get; init; } = [];
}

public sealed class ListClipboardOffersResult
{
    public IReadOnlyList<ClipboardOfferInfo> Offers { get; init; } = [];
}

public sealed class FetchClipboardContentResult
{
    public string OfferId { get; init; } = string.Empty;
    public string ContentBase64 { get; init; } = string.Empty;
    public long ByteSize { get; init; }
    public string Sha256 { get; init; } = string.Empty;
    public bool Verified { get; init; }
}

public interface IClipboardService
{
    /// <summary>
    /// Broadcasts a newly copied clipboard item offer metadata to trusted peers.
    /// </summary>
    Task BroadcastOfferAsync(string offerId, string contentType, long size, string hash, long expiresInMs, string requiredCapability, long offerSequence);

    /// <summary>
    /// Handles a received clipboard offer from a trusted peer.
    /// </summary>
    Task HandleOfferReceivedAsync(string deviceId, string payloadSourceDeviceId, string offerId, string contentType, long size, string hash, long expiresInMs, string requiredCapability, long offerSequence);

    /// <summary>
    /// Explicitly fetches the content of an offer from a peer.
    /// </summary>
    Task<byte[]> FetchContentAsync(string deviceId, string offerId);

    Task<NotifyClipboardChangeResult> NotifyClipboardChangeAsync(string contentType, long byteSize, string sha256, string contentBase64, CancellationToken cancellationToken);

    Task<ListClipboardOffersResult> ListClipboardOffersAsync();

    Task<FetchClipboardContentResult> FetchClipboardContentAsync(string offerId, CancellationToken cancellationToken);

    Task HandleFetchRequestAsync(string deviceId, string offerId, string requestingDeviceId, CancellationToken cancellationToken);

    Task HandleFetchResponseAsync(string deviceId, string offerId, string contentBase64, long byteSize, string sha256, CancellationToken cancellationToken);

    Task HandleFetchRejectAsync(string deviceId, string offerId, string failureReason, string? message, CancellationToken cancellationToken);
}
