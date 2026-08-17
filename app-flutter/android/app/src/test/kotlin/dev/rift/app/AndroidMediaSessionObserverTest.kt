package dev.rift.app

import android.media.session.PlaybackState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AndroidMediaSessionObserverTest {
    @Test
    fun combinedPlayPauseActionPublishesBothCapabilities() {
        val actions = PlaybackState.ACTION_PLAY_PAUSE

        assertTrue(AndroidMediaSessionObserver.canPlay(actions))
        assertTrue(AndroidMediaSessionObserver.canPause(actions))
    }

    @Test
    fun ownRiftPackageIsExcluded() {
        assertTrue(AndroidMediaSessionObserver.shouldObservePackage("dev.player", "dev.rift.app"))
        assertFalse(AndroidMediaSessionObserver.shouldObservePackage("dev.rift.app", "dev.rift.app"))
    }

    @Test
    fun unchangedSnapshotsAreSuppressedAfterInitialPost() {
        val stats = MutableMediaObserverStats()
        val tracker = MediaSnapshotTracker(stats)
        val candidate = snapshot()

        val decisions = (0 until 31).map {
            tracker.evaluate(candidate, forceReplay = false, artworkAvailable = false)
        }

        assertEquals("posted", decisions.first().eventType)
        assertTrue(decisions.drop(1).all { it.eventType == null })
        assertEquals(31L, stats.snapshot().snapshotCandidates)
        assertEquals(1L, stats.snapshot().snapshotsEmitted)
        assertEquals(30L, stats.snapshot().duplicateSnapshotsSuppressed)
    }

    @Test
    fun transportTimestampCannotCauseSemanticUpdate() {
        val tracker = MediaSnapshotTracker(MutableMediaObserverStats())
        val candidate = snapshot()

        tracker.evaluate(candidate, forceReplay = false, artworkAvailable = false)
        val laterDecision = tracker.evaluate(
            candidate.copy(),
            forceReplay = false,
            artworkAvailable = false,
        )

        assertNull(laterDecision.eventType)
    }

    @Test
    fun playbackStateChangeEmitsUpdate() {
        assertSemanticChangeEmits { it.copy(playbackState = "playing") }
    }

    @Test
    fun positionChangeEmitsUpdate() {
        assertSemanticChangeEmits { it.copy(positionMs = 12_000L) }
    }

    @Test
    fun capabilityChangeEmitsUpdate() {
        assertSemanticChangeEmits { it.copy(canSkipNext = true) }
    }

    @Test
    fun metadataChangesEmitUpdates() {
        val changes = listOf<(MediaSnapshotState) -> MediaSnapshotState>(
            { it.copy(title = "New title") },
            { it.copy(artist = "New artist") },
            { it.copy(album = "New album") },
            { it.copy(durationMs = 240_000L) },
        )

        changes.forEach(::assertSemanticChangeEmits)
    }

    @Test
    fun forceReplayBypassesSemanticDedupeAsPostedEvent() {
        val stats = MutableMediaObserverStats()
        val tracker = MediaSnapshotTracker(stats)
        val candidate = snapshot()

        tracker.evaluate(candidate, forceReplay = false, artworkAvailable = false)
        val replay = tracker.evaluate(candidate, forceReplay = true, artworkAvailable = false)

        assertEquals("posted", replay.eventType)
        assertEquals(2L, stats.snapshot().snapshotsEmitted)
    }

    @Test
    fun appLabelIsResolvedOncePerPackage() {
        val stats = MutableMediaObserverStats()
        val resolvedPackages = mutableListOf<String>()
        val cache = MediaAppLabelCache(
            resolver = { packageName ->
                resolvedPackages.add(packageName)
                "Label for $packageName"
            },
            stats = stats,
        )

        repeat(20) { assertEquals("Label for one", cache.labelFor("one")) }
        assertEquals("Label for two", cache.labelFor("two"))

        assertEquals(listOf("one", "two"), resolvedPackages)
        assertEquals(2L, stats.snapshot().appLabelLookups)
        assertEquals(19L, stats.snapshot().appLabelCacheHits)
    }

    @Test
    fun changedBitmapGenerationChangesSemanticArtworkIdentity() {
        val resolver = ArtworkKeyResolver()
        val bitmap = Any()
        val semanticIdentity = ArtworkSemanticIdentity(uri = "art://track")
        val original = resolver.resolve(
            playbackId = "player-1",
            bitmap = bitmap,
            bitmapIdentity = 7,
            generationId = 1,
            width = 100,
            height = 100,
            semanticIdentity = semanticIdentity,
        )
        val changed = resolver.resolve(
            playbackId = "player-1",
            bitmap = bitmap,
            bitmapIdentity = 7,
            generationId = 2,
            width = 100,
            height = 100,
            semanticIdentity = semanticIdentity,
        )

        assertNotEquals(original, changed)
        assertSemanticChangeEmits {
            it.copy(artworkKey = changed)
        }
    }

    @Test
    fun reparceledBitmapKeepsStableMetadataArtworkIdentity() {
        val resolver = ArtworkKeyResolver()
        val semanticIdentity = ArtworkSemanticIdentity(uri = "art://track")
        val original = resolver.resolve(
            playbackId = "player-1",
            bitmap = Any(),
            bitmapIdentity = 7,
            generationId = 2,
            width = 640,
            height = 360,
            semanticIdentity = semanticIdentity,
        )
        val reparceled = resolver.resolve(
            playbackId = "player-1",
            bitmap = Any(),
            bitmapIdentity = 8,
            generationId = 12,
            width = 640,
            height = 360,
            semanticIdentity = semanticIdentity,
        )

        assertEquals(original, reparceled)
    }

    @Test
    fun changedArtworkUriChangesSemanticArtworkIdentity() {
        val resolver = ArtworkKeyResolver()
        val original = resolver.resolve(
            playbackId = "player-1",
            bitmap = Any(),
            bitmapIdentity = 7,
            generationId = 2,
            width = 640,
            height = 360,
            semanticIdentity = ArtworkSemanticIdentity(uri = "art://track-a"),
        )
        val changed = resolver.resolve(
            playbackId = "player-1",
            bitmap = Any(),
            bitmapIdentity = 8,
            generationId = 12,
            width = 640,
            height = 360,
            semanticIdentity = ArtworkSemanticIdentity(uri = "art://track-b"),
        )

        assertNotEquals(original, changed)
    }

    @Test
    fun stableArtworkIdentityBookkeepingIsBounded() {
        val resolver = ArtworkKeyResolver(maxStableEntries = 2)
        repeat(3) { index ->
            resolver.resolve(
                playbackId = "player-$index",
                bitmap = Any(),
                bitmapIdentity = index,
                generationId = index,
                width = 100,
                height = 100,
                semanticIdentity = ArtworkSemanticIdentity(uri = "art://$index"),
            )
        }

        assertEquals(2, resolver.stableEntryCount())
    }

    @Test
    fun removalClearsPublicationState() {
        val tracker = MediaSnapshotTracker(MutableMediaObserverStats())
        val candidate = snapshot()
        tracker.evaluate(candidate, forceReplay = false, artworkAvailable = false)

        assertTrue(tracker.remove(candidate.playbackId))
        val next = tracker.evaluate(candidate, forceReplay = false, artworkAvailable = false)

        assertEquals("posted", next.eventType)
    }

    private fun assertSemanticChangeEmits(
        change: (MediaSnapshotState) -> MediaSnapshotState,
    ) {
        val tracker = MediaSnapshotTracker(MutableMediaObserverStats())
        val initial = snapshot()
        tracker.evaluate(initial, forceReplay = false, artworkAvailable = false)

        val decision = tracker.evaluate(
            change(initial),
            forceReplay = false,
            artworkAvailable = false,
        )

        assertEquals("updated", decision.eventType)
    }

    private fun snapshot(): MediaSnapshotState = MediaSnapshotState(
        playbackId = "player-1",
        appId = "dev.player",
        appName = "Player",
        title = "Title",
        artist = "Artist",
        album = "Album",
        playbackState = "paused",
        positionMs = 10_000L,
        durationMs = 180_000L,
        canPlay = true,
        canPause = true,
        canSkipNext = false,
        canSkipPrevious = false,
        canSeek = true,
        artworkKey = ArtworkKey(
            source = ArtworkSourceIdentity.Bitmap(7),
            revision = 1,
            width = 100,
            height = 100,
        ),
    )
}
