using System.Runtime.Versioning;
using Microsoft.Extensions.Logging.Abstractions;
using Rift.Daemon.Core.Interfaces;
using Rift.Daemon.Linux;
using Tmds.DBus.Protocol;

namespace Rift.Daemon.Tests.Core;

[SupportedOSPlatform("linux")]
public sealed class LinuxMediaPlaybackServiceTests
{
    [Theory]
    [InlineData("org.mpris.MediaPlayer2.vlc", true)]
    [InlineData("org.mpris.MediaPlayer2.playerctld", false)]
    [InlineData("org.example.Player", false)]
    public void IsPlayerService_ExcludesPlayerCtlProxy(string serviceName, bool expected)
    {
        Assert.Equal(expected, LinuxMprisClient.IsPlayerService(serviceName));
    }

    [Fact]
    public void CreateSnapshot_MapsMprisPropertiesToRiftRecord()
    {
        var metadata = new Dict<string, VariantValue>(new Dictionary<string, VariantValue>
        {
            ["mpris:trackid"] = new ObjectPath("/track/42"),
            ["mpris:length"] = 245_000_000L,
            ["mpris:artUrl"] = "file:///tmp/art.png",
            ["xesam:title"] = "Example Track",
            ["xesam:artist"] = new Tmds.DBus.Protocol.Array<string>(["Example Artist"]),
            ["xesam:album"] = "Example Album"
        });
        var root = new Dictionary<string, VariantValue>
        {
            ["DesktopEntry"] = "org.example.Player",
            ["Identity"] = "Example Player"
        };
        var player = new Dictionary<string, VariantValue>
        {
            ["Metadata"] = metadata,
            ["PlaybackStatus"] = "Playing",
            ["Position"] = 12_345_000L,
            ["CanControl"] = true,
            ["CanPlay"] = true,
            ["CanPause"] = true,
            ["CanGoNext"] = true,
            ["CanGoPrevious"] = false,
            ["CanSeek"] = true
        };

        var snapshot = LinuxMprisClient.CreateSnapshot(
            "org.mpris.MediaPlayer2.example",
            root,
            player);
        snapshot = snapshot with
        {
            Artwork = new Dictionary<string, object?>
            {
                ["dataBase64"] = "cG5n",
                ["mediaType"] = "image/png",
                ["uri"] = snapshot.ArtworkUrl
            },
            ArtworkVersion = "4:1"
        };
        var record = snapshot.ToRecord();

        Assert.Equal("org.mpris.MediaPlayer2.example:/track/42", record.PlaybackId);
        Assert.Equal("linux", record.SourcePlatform);
        Assert.Equal("org.example.Player", record.AppId);
        Assert.Equal("Example Player", record.AppName);
        Assert.Equal("Example Track", record.Title);
        Assert.Equal("Example Artist", record.Artist);
        Assert.Equal("Example Album", record.Album);
        Assert.Equal("playing", record.PlaybackState);
        Assert.Equal(12_345L, record.PositionMs);
        Assert.Equal(245_000L, record.DurationMs);
        Assert.True(record.CanSkipNext);
        Assert.False(record.CanSkipPrevious);
        Assert.Equal("file:///tmp/art.png", record.Artwork!["uri"]);
        Assert.Equal("cG5n", record.Artwork["dataBase64"]);
        Assert.Equal("image/png", record.Artwork["mediaType"]);

        player["CanControl"] = false;
        var uncontrolled = LinuxMprisClient.CreateSnapshot(
            "org.mpris.MediaPlayer2.example",
            root,
            player).ToRecord();
        Assert.False(uncontrolled.CanPlay);
        Assert.False(uncontrolled.CanPause);
        Assert.False(uncontrolled.CanSkipNext);
        Assert.False(uncontrolled.CanSeek);
    }

    [Fact]
    public async Task ArtworkLoader_EncodesLocalImageWithDetectedMediaType()
    {
        var path = Path.Combine(Path.GetTempPath(), $"rift-art-{Guid.NewGuid():N}");
        var bytes = new byte[] { 0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1, 2, 3 };
        await File.WriteAllBytesAsync(path, bytes);
        try
        {
            var loader = new LinuxMprisArtworkLoader(
                NullLogger<LinuxMprisArtworkLoader>.Instance);

            var artwork = await loader.LoadAsync(new Uri(path).AbsoluteUri, CancellationToken.None);

            Assert.NotNull(artwork);
            Assert.Equal("image/png", artwork.Payload["mediaType"]);
            Assert.Equal(Convert.ToBase64String(bytes), artwork.Payload["dataBase64"]);
            Assert.Equal(new Uri(path).AbsoluteUri, artwork.Payload["uri"]);
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Theory]
    [InlineData("https://example.com/art.png")]
    [InlineData("file://remote-host/tmp/art.png")]
    [InlineData("not a URI")]
    public async Task ArtworkLoader_RejectsNonLocalUris(string artworkUrl)
    {
        var loader = new LinuxMprisArtworkLoader(
            NullLogger<LinuxMprisArtworkLoader>.Instance);

        Assert.Null(await loader.LoadAsync(artworkUrl, CancellationToken.None));
    }

    [Fact]
    public async Task ArtworkLoader_RejectsUnsupportedFileContent()
    {
        var path = Path.Combine(Path.GetTempPath(), $"rift-art-text-{Guid.NewGuid():N}");
        await File.WriteAllTextAsync(path, "not an image");
        try
        {
            var loader = new LinuxMprisArtworkLoader(
                NullLogger<LinuxMprisArtworkLoader>.Instance);

            Assert.Null(await loader.LoadAsync(new Uri(path).AbsoluteUri, CancellationToken.None));
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public void ArtworkLoader_DetectsSupportedImageTypes()
    {
        Assert.Equal("image/png", LinuxMprisArtworkLoader.DetectMediaType(
            [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]));
        Assert.Equal("image/jpeg", LinuxMprisArtworkLoader.DetectMediaType([0xff, 0xd8, 0xff]));
        Assert.Equal("image/gif", LinuxMprisArtworkLoader.DetectMediaType("GIF89a"u8));
        Assert.Equal("image/webp", LinuxMprisArtworkLoader.DetectMediaType("RIFF1234WEBP"u8));
    }

    [Fact]
    public async Task ArtworkLoader_RejectsOversizedImage()
    {
        var path = Path.Combine(Path.GetTempPath(), $"rift-art-large-{Guid.NewGuid():N}");
        await using (var stream = File.Create(path))
        {
            stream.SetLength(LinuxMprisArtworkLoader.MaxArtworkBytes + 1L);
        }
        try
        {
            var loader = new LinuxMprisArtworkLoader(
                NullLogger<LinuxMprisArtworkLoader>.Instance);

            Assert.Null(await loader.LoadAsync(new Uri(path).AbsoluteUri, CancellationToken.None));
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public void CreateFingerprint_ChangesWhenArtworkChanges()
    {
        var snapshot = CreateSnapshot("playing", positionMs: 1_000);

        var changed = snapshot with { ArtworkVersion = "100:2" };

        Assert.NotEqual(
            LinuxMediaPlaybackService.CreateFingerprint(snapshot),
            LinuxMediaPlaybackService.CreateFingerprint(changed));
    }

    [Fact]
    public async Task PollOnceAsync_PublishesPostedUpdatedAndRemovedLifecycle()
    {
        var client = new FakeMprisClient
        {
            Snapshots = [CreateSnapshot("playing", positionMs: 1_000)]
        };
        var syncService = new RecordingMediaPlaybackSyncService();
        var service = new LinuxMediaPlaybackService(
            new StubServiceProvider(syncService),
            client,
            NullLogger<LinuxMediaPlaybackService>.Instance);

        await service.PollOnceAsync(CancellationToken.None);
        client.Snapshots = [CreateSnapshot("paused", positionMs: 1_000)];
        await service.PollOnceAsync(CancellationToken.None);
        client.Snapshots = [];
        await service.PollOnceAsync(CancellationToken.None);

        Assert.Equal(["posted", "updated", "removed"], syncService.Events.Select(item => item.EventType));
        Assert.Equal("playback-1", syncService.Events[2].Playback.PlaybackId);
        Assert.NotNull(syncService.Events[2].RemovedAt);
    }

    [Theory]
    [InlineData("play", null)]
    [InlineData("pause", null)]
    [InlineData("togglePlayPause", null)]
    [InlineData("next", null)]
    [InlineData("previous", null)]
    [InlineData("seek", 12_345L)]
    public async Task HandleActionAsync_ForwardsSupportedMprisActions(string action, long? positionMs)
    {
        var client = new FakeMprisClient();
        var service = new LinuxMediaPlaybackService(
            new StubServiceProvider(new RecordingMediaPlaybackSyncService()),
            client,
            NullLogger<LinuxMediaPlaybackService>.Instance);

        var result = await service.HandleActionAsync(
            new PendingIncomingMediaPlaybackAction
            {
                PlaybackId = "playback-1",
                Action = action,
                PositionMs = positionMs
            },
            CancellationToken.None);

        Assert.True(result.Success);
        Assert.Equal(("playback-1", action, positionMs), client.LastAction);
    }

    private static LinuxMprisSnapshot CreateSnapshot(string state, long positionMs) => new(
        PlaybackId: "playback-1",
        ServiceName: "org.mpris.MediaPlayer2.test",
        TrackId: "/track/1",
        AppId: "test-player",
        AppName: "Test Player",
        Title: "Track",
        Artist: "Artist",
        Album: "Album",
        ArtworkUrl: null,
        Artwork: null,
        ArtworkVersion: null,
        PlaybackState: state,
        PositionMs: positionMs,
        DurationMs: 30_000,
        CanPlay: true,
        CanPause: true,
        CanSkipNext: true,
        CanSkipPrevious: true,
        CanSeek: true,
        UpdatedAt: DateTimeOffset.UtcNow.ToString("O"));

    private sealed class FakeMprisClient : ILinuxMprisClient
    {
        public IReadOnlyList<LinuxMprisSnapshot> Snapshots { get; set; } = [];
        public (string PlaybackId, string Action, long? PositionMs)? LastAction { get; private set; }

        public Task<IReadOnlyList<LinuxMprisSnapshot>> GetSnapshotsAsync(CancellationToken cancellationToken) =>
            Task.FromResult(Snapshots);

        public Task ExecuteActionAsync(
            string playbackId,
            string action,
            long? positionMs,
            CancellationToken cancellationToken)
        {
            LastAction = (playbackId, action, positionMs);
            return Task.CompletedTask;
        }
    }

    private sealed class StubServiceProvider(IMediaPlaybackSyncService syncService) : IServiceProvider
    {
        public object? GetService(Type serviceType) =>
            serviceType == typeof(IMediaPlaybackSyncService) ? syncService : null;
    }

    private sealed class RecordingMediaPlaybackSyncService : IMediaPlaybackSyncService
    {
        public List<(string EventType, MediaPlaybackRecord Playback, string? RemovedAt)> Events { get; } = [];

        public Task<NotifyLocalMediaPlaybackEventResult> HandleLocalPlaybackEventAsync(
            string eventType,
            MediaPlaybackRecord playback,
            string? removedAt,
            CancellationToken cancellationToken)
        {
            Events.Add((eventType, playback, removedAt));
            return Task.FromResult(new NotifyLocalMediaPlaybackEventResult { PlaybackId = playback.PlaybackId });
        }

        public Task PublishLocalPlaybackToPeerAsync(string peerDeviceId, MediaPlaybackRecord playback, CancellationToken cancellationToken) =>
            Task.CompletedTask;

        public Task SendPeerErrorAsync(string peerDeviceId, string failureReason, string? refMessageId, string message, CancellationToken cancellationToken) => throw new NotSupportedException();
        public Task<ListMediaPlaybackResult> ListMediaPlaybackAsync(CancellationToken cancellationToken) => throw new NotSupportedException();
        public Task<MediaPlaybackRecord> GetMediaPlaybackAsync(string sourceDeviceId, string playbackId, CancellationToken cancellationToken) => throw new NotSupportedException();
        public Task<PerformMediaPlaybackActionResult> PerformMediaPlaybackActionAsync(string sourceDeviceId, string playbackId, string action, long? positionMs, CancellationToken cancellationToken) => throw new NotSupportedException();
        public Task HandleMediaPlaybackPostedAsync(MediaPlaybackRecord playback, CancellationToken cancellationToken) => throw new NotSupportedException();
        public Task HandleMediaPlaybackUpdatedAsync(MediaPlaybackRecord playback, CancellationToken cancellationToken) => throw new NotSupportedException();
        public Task HandleMediaPlaybackRemovedAsync(MediaPlaybackRemovedRecord playback, CancellationToken cancellationToken) => throw new NotSupportedException();
        public Task HandleMediaPlaybackActionResultAsync(MediaPlaybackActionResultRecord result, CancellationToken cancellationToken) => throw new NotSupportedException();
        public Task HandleMediaPlaybackActionRequestAsync(MediaPlaybackActionRequestRecord request, CancellationToken cancellationToken) => throw new NotSupportedException();
        public Task<ReportHandledMediaPlaybackActionResult> ReportHandledMediaPlaybackActionAsync(string requestId, bool success, string? failureReason, string? message, CancellationToken cancellationToken) => throw new NotSupportedException();
    }
}
