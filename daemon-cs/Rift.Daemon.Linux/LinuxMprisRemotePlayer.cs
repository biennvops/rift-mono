using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;
using Microsoft.Extensions.DependencyInjection;
using Rift.Daemon.Core.Interfaces;
using Tmds.DBus.Protocol;

namespace Rift.Daemon.Linux;

internal interface ILinuxMprisRemotePlayer
{
    Task UpdateAsync(MediaPlaybackRecord? playback, CancellationToken cancellationToken);

    Task StopAsync(CancellationToken cancellationToken);
}

internal sealed class LinuxMprisRemotePlayer(
    IServiceProvider serviceProvider,
    ILogger<LinuxMprisRemotePlayer> logger) : ILinuxMprisRemotePlayer, IPathMethodHandler
{
    internal const string ServiceName = "org.mpris.MediaPlayer2.rift";
    internal const string ObjectPath = "/org/mpris/MediaPlayer2";
    private const string RootInterface = "org.mpris.MediaPlayer2";
    private const string PlayerInterface = "org.mpris.MediaPlayer2.Player";
    private const string PropertiesInterface = "org.freedesktop.DBus.Properties";
    private const string NoTrackPath = "/org/mpris/MediaPlayer2/TrackList/NoTrack";
    private static readonly byte[] RootIntrospection = Encoding.UTF8.GetBytes("""
        <interface name="org.mpris.MediaPlayer2">
          <method name="Raise"/>
          <method name="Quit"/>
          <property name="CanQuit" type="b" access="read"/>
          <property name="CanRaise" type="b" access="read"/>
          <property name="HasTrackList" type="b" access="read"/>
          <property name="Identity" type="s" access="read"/>
          <property name="DesktopEntry" type="s" access="read"/>
          <property name="SupportedUriSchemes" type="as" access="read"/>
          <property name="SupportedMimeTypes" type="as" access="read"/>
        </interface>
        """);
    private static readonly byte[] PlayerIntrospection = Encoding.UTF8.GetBytes("""
        <interface name="org.mpris.MediaPlayer2.Player">
          <method name="Next"/>
          <method name="Previous"/>
          <method name="Pause"/>
          <method name="PlayPause"/>
          <method name="Stop"/>
          <method name="Play"/>
          <method name="Seek"><arg name="Offset" type="x" direction="in"/></method>
          <method name="SetPosition"><arg name="TrackId" type="o" direction="in"/><arg name="Position" type="x" direction="in"/></method>
          <method name="OpenUri"><arg name="Uri" type="s" direction="in"/></method>
          <signal name="Seeked"><arg name="Position" type="x"/></signal>
          <property name="PlaybackStatus" type="s" access="read"/>
          <property name="LoopStatus" type="s" access="readwrite"/>
          <property name="Rate" type="d" access="readwrite"/>
          <property name="Shuffle" type="b" access="readwrite"/>
          <property name="Metadata" type="a{sv}" access="read"/>
          <property name="Volume" type="d" access="readwrite"/>
          <property name="Position" type="x" access="read"/>
          <property name="MinimumRate" type="d" access="read"/>
          <property name="MaximumRate" type="d" access="read"/>
          <property name="CanGoNext" type="b" access="read"/>
          <property name="CanGoPrevious" type="b" access="read"/>
          <property name="CanPlay" type="b" access="read"/>
          <property name="CanPause" type="b" access="read"/>
          <property name="CanSeek" type="b" access="read"/>
          <property name="CanControl" type="b" access="read"/>
        </interface>
        """);

    private readonly SemaphoreSlim _connectionGate = new(1, 1);
    private readonly Lock _stateGate = new();
    private DBusConnection? _connection;
    private bool _nameOwned;
    private MediaPlaybackRecord? _playback;
    private string _trackPath = NoTrackPath;
    private long _positionBaseMs;
    private long _positionBaseTimestamp;
    private string? _artworkPath;

    public string Path => ObjectPath;

    public bool HandlesChildPaths => false;

    public async Task UpdateAsync(MediaPlaybackRecord? playback, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (playback is null || playback.IsRemoved || playback.PlaybackState == "stopped")
        {
            await ClearAsync(cancellationToken).ConfigureAwait(false);
            return;
        }

        if (!await EnsureConnectedAsync(cancellationToken).ConfigureAwait(false))
        {
            return;
        }

        IReadOnlyList<string> changed;
        lock (_stateGate)
        {
            changed = UpdateStateLocked(playback, cancellationToken);
        }

        if (changed.Count > 0)
        {
            await EmitPropertiesChangedAsync(changed, cancellationToken).ConfigureAwait(false);
        }
    }

    public async Task StopAsync(CancellationToken cancellationToken)
    {
        await ClearAsync(cancellationToken).ConfigureAwait(false);
        await _connectionGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (_connection is not null)
            {
                _connection.RemoveMethodHandler(ObjectPath);
                _connection.Dispose();
                _connection = null;
            }
        }
        finally
        {
            _connectionGate.Release();
        }

        CleanupArtwork();
    }

    public async ValueTask HandleMethodAsync(MethodContext context)
    {
        try
        {
            if (context.IsDBusIntrospectRequest)
            {
                context.ReplyIntrospectXml(
                    [
                        new ReadOnlyMemory<byte>(RootIntrospection),
                        new ReadOnlyMemory<byte>(PlayerIntrospection)
                    ],
                    Array.Empty<string>());
                return;
            }

            var request = context.Request;
            var @interface = request.InterfaceAsString ?? string.Empty;
            var member = request.MemberAsString ?? string.Empty;
            if (@interface == PropertiesInterface)
            {
                await HandlePropertiesAsync(context, member).ConfigureAwait(false);
                return;
            }

            if (@interface == RootInterface)
            {
                HandleRootMethod(context, member);
                return;
            }

            if (@interface == PlayerInterface)
            {
                await HandlePlayerMethodAsync(context, member).ConfigureAwait(false);
                return;
            }

            context.ReplyUnknownMethodError();
        }
        catch (Exception ex)
        {
            if (!context.HandleException(ex, shouldDisconnect: false) && !context.ReplySent)
            {
                context.ReplyError("org.freedesktop.DBus.Error.Failed", ex.Message);
            }
        }
    }

    private async Task<bool> EnsureConnectedAsync(CancellationToken cancellationToken)
    {
        await _connectionGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (_connection is not null && _nameOwned)
            {
                return true;
            }

            _connection?.Dispose();
            var options = new DBusConnectionOptions(DBusAddress.Session ?? string.Empty)
            {
                AutoConnect = false,
                OnException = context => logger.LogDebug(
                    context.Exception,
                    "Linux remote MPRIS D-Bus connection failed in {Source}.",
                    context.Source)
            };
            var connection = new DBusConnection(options);
            try
            {
                await connection.ConnectAsync().ConfigureAwait(false);
                connection.AddMethodHandler(this);
                if (!await connection.TryRequestNameAsync(ServiceName, RequestNameOptions.None).ConfigureAwait(false))
                {
                    connection.RemoveMethodHandler(ObjectPath);
                    connection.Dispose();
                    logger.LogDebug("D-Bus service name {ServiceName} is already owned.", ServiceName);
                    return false;
                }
            }
            catch
            {
                connection.Dispose();
                throw;
            }

            _connection = connection;
            _nameOwned = true;
            _ = ObserveConnectionAsync(connection);
            return true;
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            logger.LogDebug(ex, "Linux remote MPRIS player is unavailable.");
            return false;
        }
        finally
        {
            _connectionGate.Release();
        }
    }

    private async Task ObserveConnectionAsync(DBusConnection connection)
    {
        try
        {
            await connection.DisconnectedAsync().ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            logger.LogDebug(ex, "Linux remote MPRIS D-Bus connection observation failed.");
        }

        if (ReferenceEquals(Volatile.Read(ref _connection), connection))
        {
            _nameOwned = false;
            Volatile.Write(ref _connection, null);
        }
    }

    private async Task ClearAsync(CancellationToken cancellationToken)
    {
        DBusConnection? connection;
        lock (_stateGate)
        {
            _playback = null;
            _trackPath = NoTrackPath;
            _positionBaseMs = 0;
            _positionBaseTimestamp = 0;
        }
        CleanupArtwork();

        await _connectionGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            connection = _connection;
            if (connection is null || !_nameOwned)
            {
                return;
            }

            _nameOwned = false;
            await connection.ReleaseNameAsync(ServiceName).ConfigureAwait(false);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            logger.LogDebug(ex, "Failed to release Linux remote MPRIS service name.");
        }
        finally
        {
            _connectionGate.Release();
        }
    }

    private IReadOnlyList<string> UpdateStateLocked(
        MediaPlaybackRecord playback,
        CancellationToken cancellationToken)
    {
        var old = _playback;
        var keyChanged = old is null ||
                         !string.Equals(old.SourceDeviceId, playback.SourceDeviceId, StringComparison.Ordinal) ||
                         !string.Equals(old.PlaybackId, playback.PlaybackId, StringComparison.Ordinal);
        var positionChanged = old is null ||
                              old.PositionMs != playback.PositionMs ||
                              old.PlaybackState != playback.PlaybackState ||
                              keyChanged;
        _playback = playback;
        _trackPath = keyChanged ? CreateTrackPath(playback.SourceDeviceId, playback.PlaybackId) : _trackPath;
        if (positionChanged)
        {
            _positionBaseMs = playback.PositionMs;
            _positionBaseTimestamp = Stopwatch.GetTimestamp();
        }

        if (playback.Artwork is not null &&
            playback.Artwork.TryGetValue("dataBase64", out var artworkValue) &&
            artworkValue is string dataBase64 &&
            playback.Artwork.TryGetValue("mediaType", out var mediaTypeValue) &&
            mediaTypeValue is string mediaType)
        {
            try
            {
                WriteArtwork(dataBase64, mediaType, cancellationToken);
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                logger.LogDebug(ex, "Failed to materialize remote MPRIS artwork.");
                CleanupArtwork();
            }
        }
        else
        {
            CleanupArtwork();
        }

        if (old is null || keyChanged)
        {
            return [
                "PlaybackStatus", "Metadata", "Position", "CanGoNext", "CanGoPrevious",
                "CanPlay", "CanPause", "CanSeek", "CanControl"
            ];
        }

        var changed = new List<string>();
        if (old.PlaybackState != playback.PlaybackState) changed.Add("PlaybackStatus");
        if (old.PositionMs != playback.PositionMs || old.DurationMs != playback.DurationMs) changed.Add("Position");
        if (old.Title != playback.Title ||
            old.Artist != playback.Artist ||
            old.Album != playback.Album ||
            old.DurationMs != playback.DurationMs ||
            !ArtworkEquals(old.Artwork, playback.Artwork))
        {
            changed.Add("Metadata");
        }
        if (old.CanSkipNext != playback.CanSkipNext) changed.Add("CanGoNext");
        if (old.CanSkipPrevious != playback.CanSkipPrevious) changed.Add("CanGoPrevious");
        if (CanMprisPlay(old) != CanMprisPlay(playback)) changed.Add("CanPlay");
        if (old.CanPause != playback.CanPause) changed.Add("CanPause");
        if (old.CanSeek != playback.CanSeek) changed.Add("CanSeek");
        if (CanControl(old) != CanControl(playback)) changed.Add("CanControl");
        return changed.Distinct(StringComparer.Ordinal).ToArray();
    }

    private static bool CanControl(MediaPlaybackRecord playback) =>
        playback.CanPlay ||
        playback.CanPause ||
        playback.CanSkipNext ||
        playback.CanSkipPrevious ||
        playback.CanSeek;

    private static bool ArtworkEquals(
        IReadOnlyDictionary<string, object?>? left,
        IReadOnlyDictionary<string, object?>? right)
    {
        if (ReferenceEquals(left, right))
        {
            return true;
        }
        if (left is null || right is null || left.Count != right.Count)
        {
            return false;
        }
        return left.All(entry => right.TryGetValue(entry.Key, out var value) && Equals(entry.Value, value));
    }

    private void WriteArtwork(string dataBase64, string mediaType, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var bytes = Convert.FromBase64String(dataBase64);
        var extension = mediaType switch
        {
            "image/png" => ".png",
            "image/jpeg" => ".jpg",
            "image/gif" => ".gif",
            "image/webp" => ".webp",
            _ => throw new InvalidOperationException($"Unsupported artwork media type '{mediaType}'.")
        };
        var directory = System.IO.Path.Combine(
            Environment.GetEnvironmentVariable("XDG_RUNTIME_DIR") ?? System.IO.Path.GetTempPath(),
            "rift-daemon",
            "media-artwork");
        Directory.CreateDirectory(directory);
        File.SetUnixFileMode(
            directory,
            UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
        var path = System.IO.Path.Combine(directory, $"remote-{Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant()}{extension}");
        if (!File.Exists(path))
        {
            File.WriteAllBytes(path, bytes);
            File.SetUnixFileMode(path, UnixFileMode.UserRead | UnixFileMode.UserWrite);
        }
        if (!string.Equals(_artworkPath, path, StringComparison.Ordinal))
        {
            CleanupArtwork();
            _artworkPath = path;
        }
    }

    private void CleanupArtwork()
    {
        var path = Interlocked.Exchange(ref _artworkPath, null);
        if (path is not null)
        {
            try { File.Delete(path); }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
    }

    private async Task HandlePropertiesAsync(MethodContext context, string member)
    {
        var reader = context.Request.GetBodyReader();
        if (member == "Get")
        {
            var @interface = reader.ReadString();
            var property = reader.ReadString();
            if (!TryGetProperty(@interface, property, out var value))
            {
                context.ReplyError("org.freedesktop.DBus.Error.UnknownProperty", property);
                return;
            }
            if (!context.NoReplyExpected)
            {
                using var writer = context.CreateReplyWriter("v");
                writer.WriteVariant(value);
                context.Reply(writer.CreateMessage());
            }
            return;
        }

        if (member == "GetAll")
        {
            var @interface = reader.ReadString();
            var values = GetProperties(@interface);
            if (!context.NoReplyExpected)
            {
                using var writer = context.CreateReplyWriter("a{sv}");
                writer.WriteDictionary(values);
                context.Reply(writer.CreateMessage());
            }
            return;
        }

        if (member == "Set")
        {
            context.ReplyError("org.freedesktop.DBus.Error.PropertyReadOnly", "Remote playback properties are read-only.");
            return;
        }

        context.ReplyUnknownMethodError();
        await Task.CompletedTask.ConfigureAwait(false);
    }

    private void HandleRootMethod(MethodContext context, string member)
    {
        if (member == "Raise")
        {
            ReplyEmpty(context);
            return;
        }

        context.ReplyError(
            member == "Quit" ? "org.freedesktop.DBus.Error.NotSupported" : "org.freedesktop.DBus.Error.UnknownMethod",
            "The Rift remote MPRIS player does not support this operation.");
    }

    private async Task HandlePlayerMethodAsync(MethodContext context, string member)
    {
        var reader = context.Request.GetBodyReader();
        switch (member)
        {
            case "Play":
                await RouteActionAsync(context, "play", null).ConfigureAwait(false);
                return;
            case "Pause":
                await RouteActionAsync(context, "pause", null).ConfigureAwait(false);
                return;
            case "PlayPause":
                await RouteActionAsync(context, "togglePlayPause", null).ConfigureAwait(false);
                return;
            case "Next":
                await RouteActionAsync(context, "next", null).ConfigureAwait(false);
                return;
            case "Previous":
                await RouteActionAsync(context, "previous", null).ConfigureAwait(false);
                return;
            case "Seek":
                {
                    var offsetMs = reader.ReadInt64() / 1000L;
                    MediaPlaybackRecord? playback;
                    lock (_stateGate) playback = _playback;
                    if (playback is null)
                    {
                        ReplyFailure(context, "No remote playback is active.");
                        return;
                    }
                    long currentPosition;
                    lock (_stateGate) currentPosition = GetPositionMsLocked();
                    var position = Math.Max(0L, currentPosition + offsetMs);
                    if (playback.DurationMs.HasValue) position = Math.Min(position, playback.DurationMs.Value);
                    await RouteActionAsync(context, "seek", position).ConfigureAwait(false);
                    return;
                }
            case "SetPosition":
                {
                    var trackPath = reader.ReadObjectPathAsString();
                    var positionMs = Math.Max(0L, reader.ReadInt64() / 1000L);
                    lock (_stateGate)
                    {
                        if (!string.Equals(trackPath, _trackPath, StringComparison.Ordinal))
                        {
                            ReplyFailure(context, "The remote playback track has changed.");
                            return;
                        }
                        if (_playback?.DurationMs is long durationMs)
                        {
                            positionMs = Math.Min(positionMs, durationMs);
                        }
                    }
                    await RouteActionAsync(context, "seek", positionMs).ConfigureAwait(false);
                    return;
                }
            default:
                context.ReplyError("org.freedesktop.DBus.Error.NotSupported", $"Unsupported MPRIS operation '{member}'.");
                return;
        }
    }

    private async Task RouteActionAsync(MethodContext context, string action, long? positionMs)
    {
        MediaPlaybackRecord? playback;
        lock (_stateGate) playback = _playback;
        if (playback is null)
        {
            ReplyFailure(context, "No remote playback is active.");
            return;
        }

        if (action == "play" && IsActivelyPlaying(playback.PlaybackState))
        {
            ReplyEmpty(context);
            return;
        }

        try
        {
            await serviceProvider.GetRequiredService<IMediaPlaybackSyncService>()
                .PerformMediaPlaybackActionAsync(
                    playback.SourceDeviceId,
                    playback.PlaybackId,
                    action,
                    positionMs,
                    context.RequestAborted)
                .ConfigureAwait(false);
            ReplyEmpty(context);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            ReplyFailure(context, ex.Message);
        }
    }

    private bool TryGetProperty(string @interface, string property, out VariantValue value)
    {
        value = default;
        var values = GetProperties(@interface);
        return values.TryGetValue(property, out value);
    }

    private Dictionary<string, VariantValue> GetProperties(string @interface)
    {
        if (@interface == RootInterface)
        {
            return new Dictionary<string, VariantValue>(StringComparer.Ordinal)
            {
                ["CanQuit"] = false,
                ["CanRaise"] = false,
                ["HasTrackList"] = false,
                ["Identity"] = "Rift",
                ["DesktopEntry"] = "dev.rift.Rift",
                ["SupportedUriSchemes"] = VariantValue.Array(Array.Empty<string>()),
                ["SupportedMimeTypes"] = VariantValue.Array(Array.Empty<string>())
            };
        }

        if (@interface != PlayerInterface)
        {
            return new Dictionary<string, VariantValue>(StringComparer.Ordinal);
        }

        MediaPlaybackRecord? playback;
        string trackPath;
        long positionMs;
        string? artworkPath;
        lock (_stateGate)
        {
            playback = _playback;
            trackPath = _trackPath;
            positionMs = GetPositionMsLocked();
            artworkPath = _artworkPath;
        }

        return new Dictionary<string, VariantValue>(StringComparer.Ordinal)
        {
            ["PlaybackStatus"] = ToMprisPlaybackStatus(playback?.PlaybackState),
            ["LoopStatus"] = "None",
            ["Rate"] = 1d,
            ["Shuffle"] = false,
            ["Metadata"] = CreateMetadata(playback, trackPath, artworkPath),
            ["Volume"] = 1d,
            ["Position"] = positionMs * 1000L,
            ["MinimumRate"] = 1d,
            ["MaximumRate"] = 1d,
            ["CanGoNext"] = playback?.CanSkipNext == true,
            ["CanGoPrevious"] = playback?.CanSkipPrevious == true,
            ["CanPlay"] = playback is not null && CanMprisPlay(playback),
            ["CanPause"] = playback?.CanPause == true,
            ["CanSeek"] = playback?.CanSeek == true,
            ["CanControl"] = playback is not null && CanControl(playback)
        };
    }

    internal static string ToMprisPlaybackStatus(string? playbackState) => playbackState switch
    {
        "playing" or "buffering" => "Playing",
        "paused" => "Paused",
        _ => "Stopped"
    };

    internal static bool CanMprisPlay(MediaPlaybackRecord playback) =>
        playback.CanPlay || IsActivelyPlaying(playback.PlaybackState);

    private static bool IsActivelyPlaying(string? playbackState) =>
        playbackState is "playing" or "buffering";

    private long GetPositionMsLocked()
    {
        if (_playback?.PlaybackState != "playing" || _positionBaseTimestamp == 0)
        {
            return _positionBaseMs;
        }

        var elapsed = Stopwatch.GetElapsedTime(_positionBaseTimestamp).TotalMilliseconds;
        var position = _positionBaseMs + (long)Math.Max(0d, elapsed);
        return _playback.DurationMs.HasValue ? Math.Min(position, _playback.DurationMs.Value) : position;
    }

    private static VariantValue CreateMetadata(
        MediaPlaybackRecord? playback,
        string trackPath,
        string? artworkPath)
    {
        var metadata = new Dictionary<string, VariantValue>(StringComparer.Ordinal)
        {
            ["mpris:trackid"] = VariantValue.ObjectPath(new ObjectPath(trackPath))
        };
        if (playback is not null)
        {
            metadata["xesam:title"] = string.IsNullOrWhiteSpace(playback.Title)
                ? playback.AppName
                : playback.Title;
            if (!string.IsNullOrWhiteSpace(playback.Artist)) metadata["xesam:artist"] = VariantValue.Array(new[] { playback.Artist });
            if (!string.IsNullOrWhiteSpace(playback.Album)) metadata["xesam:album"] = playback.Album;
            if (playback.DurationMs.HasValue) metadata["mpris:length"] = playback.DurationMs.Value * 1000L;
            if (!string.IsNullOrWhiteSpace(artworkPath)) metadata["mpris:artUrl"] = new Uri(artworkPath).AbsoluteUri;
        }
        return new Dict<string, VariantValue>(metadata);
    }

    private Task EmitPropertiesChangedAsync(
        IReadOnlyList<string> properties,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        DBusConnection? connection = _connection;
        if (connection is null || !_nameOwned)
        {
            return Task.CompletedTask;
        }

        var all = GetProperties(PlayerInterface);
        var changed = properties
            .Distinct(StringComparer.Ordinal)
            .Where(all.ContainsKey)
            .ToDictionary(property => property, property => all[property], StringComparer.Ordinal);
        using var writer = connection.GetMessageWriter();
        writer.WriteSignalHeader(
            null!,
            ObjectPath,
            PropertiesInterface,
            "PropertiesChanged",
            "sa{sv}as");
        writer.WriteString(PlayerInterface);
        writer.WriteDictionary(changed);
        writer.WriteArray(Array.Empty<string>());
        var message = writer.CreateMessage();
        if (!connection.TrySendMessage(message))
        {
            logger.LogDebug("Failed to send Linux remote MPRIS property update.");
            _nameOwned = false;
            if (ReferenceEquals(_connection, connection))
            {
                _connection = null;
                connection.Dispose();
            }
        }
        return Task.CompletedTask;
    }

    private static void ReplyEmpty(MethodContext context)
    {
        if (!context.NoReplyExpected)
        {
            using var writer = context.CreateReplyWriter(null!);
            context.Reply(writer.CreateMessage());
        }
    }

    private static void ReplyFailure(MethodContext context, string message) =>
        context.ReplyError("org.freedesktop.DBus.Error.Failed", message);

    internal static string CreateTrackPath(string sourceDeviceId, string playbackId)
    {
        var bytes = SHA256.HashData(Encoding.UTF8.GetBytes($"{sourceDeviceId}\n{playbackId}"));
        return $"/org/mpris/MediaPlayer2/TrackList/Rift/{Convert.ToHexString(bytes).ToLowerInvariant()}";
    }
}
