using System.Collections.Concurrent;
using Rift.Daemon.Core.Interfaces;
using Tmds.DBus.Protocol;

namespace Rift.Daemon.Linux;

internal interface ILinuxMprisClient
{
    Task<IReadOnlyList<LinuxMprisSnapshot>> GetSnapshotsAsync(CancellationToken cancellationToken);

    Task ExecuteActionAsync(
        string playbackId,
        string action,
        long? positionMs,
        CancellationToken cancellationToken);
}

internal sealed record LinuxMprisSnapshot(
    string PlaybackId,
    string ServiceName,
    string TrackId,
    string AppId,
    string AppName,
    string? Title,
    string? Artist,
    string? Album,
    string? ArtworkUrl,
    IReadOnlyDictionary<string, object?>? Artwork,
    string? ArtworkVersion,
    string PlaybackState,
    long PositionMs,
    long? DurationMs,
    bool CanPlay,
    bool CanPause,
    bool CanSkipNext,
    bool CanSkipPrevious,
    bool CanSeek,
    string UpdatedAt)
{
    public MediaPlaybackRecord ToRecord() => new()
    {
        PlaybackId = PlaybackId,
        SourcePlatform = "linux",
        AppId = AppId,
        AppName = AppName,
        Title = Title,
        Artist = Artist,
        Album = Album,
        Artwork = Artwork,
        PlaybackState = PlaybackState,
        PositionMs = PositionMs,
        DurationMs = DurationMs,
        CanPlay = CanPlay,
        CanPause = CanPause,
        CanSkipNext = CanSkipNext,
        CanSkipPrevious = CanSkipPrevious,
        CanSeek = CanSeek,
        UpdatedAt = UpdatedAt
    };
}

internal sealed class LinuxMprisClient(
    ILinuxMprisArtworkLoader artworkLoader,
    ILogger<LinuxMprisClient> logger) : ILinuxMprisClient
{
    private const string MprisObjectPath = "/org/mpris/MediaPlayer2";
    private const string PropertiesInterface = "org.freedesktop.DBus.Properties";
    private const string RootInterface = "org.mpris.MediaPlayer2";
    private const string PlayerInterface = "org.mpris.MediaPlayer2.Player";
    private const string ServicePrefix = "org.mpris.MediaPlayer2.";
    private const string PlayerCtlProxyService = "org.mpris.MediaPlayer2.playerctld";

    private readonly DBusConnection _connection = DBusConnection.Session;
    private readonly ConcurrentDictionary<string, MprisEndpoint> _endpoints = new(StringComparer.Ordinal);

    public async Task<IReadOnlyList<LinuxMprisSnapshot>> GetSnapshotsAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        await _connection.ConnectAsync().ConfigureAwait(false);
        var serviceNames = await _connection.ListServicesAsync().ConfigureAwait(false);
        var snapshots = new List<LinuxMprisSnapshot>();
        var endpoints = new Dictionary<string, MprisEndpoint>(StringComparer.Ordinal);

        foreach (var serviceName in serviceNames
                     .Where(name => IsPlayerService(name))
                     .OrderBy(name => name, StringComparer.Ordinal))
        {
            cancellationToken.ThrowIfCancellationRequested();
            try
            {
                var root = await GetAllPropertiesAsync(serviceName, RootInterface).ConfigureAwait(false);
                var player = await GetAllPropertiesAsync(serviceName, PlayerInterface).ConfigureAwait(false);
                var snapshot = CreateSnapshot(serviceName, root, player);
                var artwork = await artworkLoader.LoadAsync(
                    snapshot.ArtworkUrl,
                    cancellationToken).ConfigureAwait(false);
                snapshot = snapshot with
                {
                    Artwork = artwork?.Payload,
                    ArtworkVersion = artwork?.Version
                };
                snapshots.Add(snapshot);
                endpoints[snapshot.PlaybackId] = new MprisEndpoint(serviceName, snapshot.TrackId);
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                throw;
            }
            catch (Exception ex)
            {
                logger.LogDebug(ex, "Failed to read MPRIS player {ServiceName}.", serviceName);
            }
        }

        cancellationToken.ThrowIfCancellationRequested();
        _endpoints.Clear();
        foreach (var endpoint in endpoints)
        {
            _endpoints[endpoint.Key] = endpoint.Value;
        }
        return snapshots;
    }

    public async Task ExecuteActionAsync(
        string playbackId,
        string action,
        long? positionMs,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (!_endpoints.TryGetValue(playbackId, out var endpoint))
        {
            throw new InvalidOperationException($"MPRIS playback '{playbackId}' is no longer available.");
        }

        var member = action switch
        {
            "play" => "Play",
            "pause" => "Pause",
            "togglePlayPause" => "PlayPause",
            "next" => "Next",
            "previous" => "Previous",
            "seek" when positionMs.HasValue => "SetPosition",
            _ => throw new InvalidOperationException($"Unsupported MPRIS action '{action}'.")
        };

        MessageBuffer message;
        using (var writer = _connection.GetMessageWriter())
        {
            if (member == "SetPosition")
            {
                writer.WriteMethodCallHeader(
                    endpoint.ServiceName,
                    MprisObjectPath,
                    PlayerInterface,
                    member,
                    "ox",
                    MessageFlags.None);
                writer.WriteObjectPath(new ObjectPath(endpoint.TrackId));
                writer.WriteInt64(checked(positionMs!.Value * 1000L));
            }
            else
            {
                writer.WriteMethodCallHeader(
                    endpoint.ServiceName,
                    MprisObjectPath,
                    PlayerInterface,
                    member,
                    string.Empty,
                    MessageFlags.None);
            }
            message = writer.CreateMessage();
        }

        await _connection.CallMethodAsync(message).ConfigureAwait(false);
    }

    internal static bool IsPlayerService(string serviceName) =>
        serviceName.StartsWith(ServicePrefix, StringComparison.Ordinal) &&
        !string.Equals(serviceName, PlayerCtlProxyService, StringComparison.Ordinal);

    internal static LinuxMprisSnapshot CreateSnapshot(
        string serviceName,
        IReadOnlyDictionary<string, VariantValue> root,
        IReadOnlyDictionary<string, VariantValue> player)
    {
        var metadata = GetDictionary(player, "Metadata");
        var trackId = GetObjectPath(metadata, "mpris:trackid") ?? "/org/mpris/MediaPlayer2/TrackList/NoTrack";
        var title = GetString(metadata, "xesam:title");
        var artist = GetStringArray(metadata, "xesam:artist")?.FirstOrDefault();
        var album = GetString(metadata, "xesam:album");
        var durationMicros = GetInt64(metadata, "mpris:length");
        var serviceSuffix = serviceName[ServicePrefix.Length..];
        var appId = GetString(root, "DesktopEntry") ?? serviceSuffix;
        var appName = GetString(root, "Identity") ?? serviceSuffix;
        var status = GetString(player, "PlaybackStatus") ?? "Stopped";
        var playbackState = status switch
        {
            "Playing" => "playing",
            "Paused" => "paused",
            _ => "stopped"
        };
        var positionMicros = Math.Max(0L, GetInt64(player, "Position") ?? 0L);
        var playbackId = $"{serviceName}:{trackId}";
        var canControl = GetBool(player, "CanControl");

        return new LinuxMprisSnapshot(
            PlaybackId: playbackId,
            ServiceName: serviceName,
            TrackId: trackId,
            AppId: appId,
            AppName: appName,
            Title: title,
            Artist: artist,
            Album: album,
            ArtworkUrl: GetString(metadata, "mpris:artUrl"),
            Artwork: null,
            ArtworkVersion: null,
            PlaybackState: playbackState,
            PositionMs: positionMicros / 1000L,
            DurationMs: durationMicros.HasValue ? Math.Max(0L, durationMicros.Value / 1000L) : null,
            CanPlay: canControl && GetBool(player, "CanPlay"),
            CanPause: canControl && GetBool(player, "CanPause"),
            CanSkipNext: canControl && GetBool(player, "CanGoNext"),
            CanSkipPrevious: canControl && GetBool(player, "CanGoPrevious"),
            CanSeek: canControl && GetBool(player, "CanSeek"),
            UpdatedAt: DateTimeOffset.UtcNow.ToString("O"));
    }

    private async Task<Dictionary<string, VariantValue>> GetAllPropertiesAsync(
        string serviceName,
        string interfaceName)
    {
        MessageBuffer message;
        using (var writer = _connection.GetMessageWriter())
        {
            writer.WriteMethodCallHeader(
                serviceName,
                MprisObjectPath,
                PropertiesInterface,
                "GetAll",
                "s",
                MessageFlags.None);
            writer.WriteString(interfaceName);
            message = writer.CreateMessage();
        }
        return await _connection.CallMethodAsync(
            message,
            static (reply, _) => reply.GetBodyReader().ReadDictionaryOfStringToVariantValue(),
            readerState: null).ConfigureAwait(false);
    }

    private static IReadOnlyDictionary<string, VariantValue> GetDictionary(
        IReadOnlyDictionary<string, VariantValue> values,
        string key)
    {
        if (!values.TryGetValue(key, out var value) || value.Type != VariantValueType.Dictionary)
        {
            return new Dictionary<string, VariantValue>();
        }
        return value.GetDictionary<string, VariantValue>();
    }

    private static string? GetString(IReadOnlyDictionary<string, VariantValue> values, string key) =>
        values.TryGetValue(key, out var value) && value.Type == VariantValueType.String
            ? value.GetString()
            : null;

    private static string[]? GetStringArray(IReadOnlyDictionary<string, VariantValue> values, string key) =>
        values.TryGetValue(key, out var value) &&
        value.Type == VariantValueType.Array &&
        value.ItemType == VariantValueType.String
            ? value.GetArray<string>()
            : null;

    private static string? GetObjectPath(IReadOnlyDictionary<string, VariantValue> values, string key) =>
        values.TryGetValue(key, out var value) && value.Type == VariantValueType.ObjectPath
            ? value.GetObjectPathAsString()
            : null;

    private static long? GetInt64(IReadOnlyDictionary<string, VariantValue> values, string key) =>
        values.TryGetValue(key, out var value) && value.Type == VariantValueType.Int64
            ? value.GetInt64()
            : null;

    private static bool GetBool(IReadOnlyDictionary<string, VariantValue> values, string key) =>
        values.TryGetValue(key, out var value) && value.Type == VariantValueType.Bool && value.GetBool();

    private sealed record MprisEndpoint(string ServiceName, string TrackId);
}
