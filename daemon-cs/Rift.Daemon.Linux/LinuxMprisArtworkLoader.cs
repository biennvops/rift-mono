namespace Rift.Daemon.Linux;

internal sealed record LinuxMprisArtwork(
    IReadOnlyDictionary<string, object?> Payload,
    string Version);

internal interface ILinuxMprisArtworkLoader
{
    Task<LinuxMprisArtwork?> LoadAsync(string? artworkUrl, CancellationToken cancellationToken);
}

internal sealed class LinuxMprisArtworkLoader(
    ILogger<LinuxMprisArtworkLoader> logger) : ILinuxMprisArtworkLoader
{
    internal const int MaxSourceArtworkBytes = 20 * 1024 * 1024;
    private const int MaxCacheEntries = 4;

    private readonly Lock _gate = new();
    private readonly Dictionary<string, CacheEntry> _cache = new(StringComparer.Ordinal);

    public async Task<LinuxMprisArtwork?> LoadAsync(
        string? artworkUrl,
        CancellationToken cancellationToken)
    {
        if (!TryResolveFilePath(artworkUrl, out var filePath))
        {
            return null;
        }

        try
        {
            var file = new FileInfo(filePath);
            if (!file.Exists || file.Length is <= 0 or > MaxSourceArtworkBytes)
            {
                return null;
            }

            var version = $"{file.Length}:{file.LastWriteTimeUtc.Ticks}";
            lock (_gate)
            {
                if (_cache.TryGetValue(filePath, out var cached) && cached.Version == version)
                {
                    return cached.Artwork;
                }
            }

            var bytes = new byte[checked((int)file.Length)];
            await using (var stream = new FileStream(
                             filePath,
                             FileMode.Open,
                             FileAccess.Read,
                             FileShare.ReadWrite | FileShare.Delete,
                             bufferSize: 81920,
                             FileOptions.Asynchronous | FileOptions.SequentialScan))
            {
                await stream.ReadExactlyAsync(bytes, cancellationToken).ConfigureAwait(false);
                if (stream.ReadByte() != -1)
                {
                    return null;
                }
            }

            var mediaType = DetectMediaType(bytes);
            if (mediaType is null)
            {
                return null;
            }

            var artwork = new LinuxMprisArtwork(
                new Dictionary<string, object?>
                {
                    ["dataBase64"] = Convert.ToBase64String(bytes),
                    ["mediaType"] = mediaType,
                    ["uri"] = artworkUrl
                },
                version);

            lock (_gate)
            {
                if (_cache.Count >= MaxCacheEntries && !_cache.ContainsKey(filePath))
                {
                    _cache.Remove(_cache.Keys.First());
                }
                _cache[filePath] = new CacheEntry(version, artwork);
            }
            return artwork;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            logger.LogDebug(ex, "Failed to load MPRIS artwork from {ArtworkUrl}.", artworkUrl);
            return null;
        }
    }

    internal static bool TryResolveFilePath(string? artworkUrl, out string filePath)
    {
        filePath = string.Empty;
        if (string.IsNullOrWhiteSpace(artworkUrl) ||
            !Uri.TryCreate(artworkUrl, UriKind.Absolute, out var uri) ||
            !uri.IsFile ||
            (!string.IsNullOrEmpty(uri.Host) && !string.Equals(uri.Host, "localhost", StringComparison.OrdinalIgnoreCase)))
        {
            return false;
        }

        filePath = uri.LocalPath;
        return Path.IsPathFullyQualified(filePath);
    }

    internal static string? DetectMediaType(ReadOnlySpan<byte> bytes)
    {
        if (bytes.StartsWith((byte[])[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))
        {
            return "image/png";
        }
        if (bytes.StartsWith((byte[])[0xff, 0xd8, 0xff]))
        {
            return "image/jpeg";
        }
        if (bytes.StartsWith("GIF87a"u8) || bytes.StartsWith("GIF89a"u8))
        {
            return "image/gif";
        }
        if (bytes.Length >= 12 &&
            bytes[..4].SequenceEqual("RIFF"u8) &&
            bytes.Slice(8, 4).SequenceEqual("WEBP"u8))
        {
            return "image/webp";
        }
        return null;
    }

    private sealed record CacheEntry(string Version, LinuxMprisArtwork Artwork);
}
