package dev.rift.app

import java.util.ArrayDeque
import java.util.concurrent.Executor
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AndroidMediaArtworkPipelineTest {
    @Test
    fun cachedArtworkAvoidsAnotherEncode() {
        val executor = QueuedExecutor()
        val dispatcher = QueuedDispatcher()
        var encodeCount = 0
        val received = mutableListOf<String>()
        val pipeline = pipeline(executor, dispatcher) { source ->
            encodeCount += 1
            "encoded:$source"
        }

        pipeline.request("art", "source", "first", received::add)
        executor.runAll()
        dispatcher.runAll()
        repeat(10) {
            pipeline.request("art", "ignored", "first", received::add)
        }

        assertEquals(1, encodeCount)
        assertEquals(11, received.size)
        assertEquals(1, pipeline.cacheSize())
    }

    @Test
    fun stablePollingAfterArtworkCompletionDoesNoAdditionalWork() {
        val stats = MutableMediaObserverStats()
        val tracker = MediaSnapshotTracker(stats)
        val labels = MediaAppLabelCache({ "Player" }, stats)
        val executor = QueuedExecutor()
        val dispatcher = QueuedDispatcher()
        val pipeline = ArtworkPipeline<String, String, String>(
            cacheEntries = 2,
            executor = executor,
            completionDispatcher = dispatcher::dispatch,
            encoder = { "encoded:$it" },
            onRequest = { stats.artworkRequests.incrementAndGet() },
            onCacheHit = { stats.artworkCacheHits.incrementAndGet() },
            onEncodeStarted = { stats.artworkEncodeStarted.incrementAndGet() },
            onEncodeCompleted = { stats.artworkEncodeCompleted.incrementAndGet() },
        )
        val artwork = ArtworkKey(1, 1, 100, 100)
        val candidate = snapshot(artwork).copy(appName = labels.labelFor("dev.player"))
        val initial = tracker.evaluate(candidate, false, artworkAvailable = false)
        pipeline.request("art", "source", candidate.playbackId) {
            tracker.artworkReady(candidate.playbackId, initial.generation, artwork)
        }
        executor.runAll()
        dispatcher.runAll()

        repeat(30) {
            val polled = candidate.copy(appName = labels.labelFor("dev.player"))
            val cached = pipeline.lookup("art")
            assertNull(tracker.evaluate(polled, false, cached.value != null).eventType)
        }

        val measured = stats.snapshot()
        assertEquals(31L, measured.snapshotCandidates)
        assertEquals(2L, measured.snapshotsEmitted)
        assertEquals(30L, measured.duplicateSnapshotsSuppressed)
        assertEquals(1L, measured.appLabelLookups)
        assertEquals(1L, measured.artworkRequests)
        assertEquals(1L, measured.artworkEncodeStarted)
        assertEquals(1L, measured.artworkEncodeCompleted)
    }

    @Test
    fun concurrentRequestsForSameArtworkShareOneEncode() {
        val executor = QueuedExecutor()
        val dispatcher = QueuedDispatcher()
        var encodeCount = 0
        val received = mutableListOf<String>()
        val pipeline = pipeline(executor, dispatcher) { source ->
            encodeCount += 1
            "encoded:$source"
        }

        pipeline.request("art", "source", "one", received::add)
        pipeline.request("art", "source", "two", received::add)

        assertEquals(1, executor.size)
        assertEquals(1, pipeline.inFlightCount())
        executor.runAll()
        dispatcher.runAll()
        assertEquals(1, encodeCount)
        assertEquals(listOf("encoded:source", "encoded:source"), received)
    }

    @Test
    fun changedBitmapGenerationStartsNewEncode() {
        val executor = QueuedExecutor()
        val dispatcher = QueuedDispatcher()
        var encodeCount = 0
        val pipeline = ArtworkPipeline<ArtworkKey, String, String>(
            cacheEntries = 2,
            executor = executor,
            completionDispatcher = dispatcher::dispatch,
            encoder = { source ->
                encodeCount += 1
                source
            },
        )
        val original = ArtworkKey(1, 1, 100, 100)
        val changed = original.copy(generationId = 2)

        pipeline.request(original, "old", "player") {}
        executor.runAll()
        dispatcher.runAll()
        pipeline.request(changed, "new", "player") {}
        executor.runAll()
        dispatcher.runAll()

        assertEquals(2, encodeCount)
    }

    @Test
    fun encodingDoesNotRunOnSnapshotRequestPath() {
        val executor = QueuedExecutor()
        val dispatcher = QueuedDispatcher()
        var encoded = false
        val pipeline = pipeline(executor, dispatcher) { source ->
            encoded = true
            source
        }

        pipeline.request("art", "source", "player") {}

        assertFalse(encoded)
        assertEquals(1, executor.size)
        executor.runAll()
        assertTrue(encoded)
    }

    @Test
    fun requesterMovingToNewArtworkCannotReceiveOldCompletion() {
        val executor = QueuedExecutor()
        val dispatcher = QueuedDispatcher()
        val received = mutableListOf<String>()
        val pipeline = pipeline(executor, dispatcher) { source -> "encoded:$source" }

        pipeline.request("old-art", "old", "player", received::add)
        pipeline.request("new-art", "new", "player", received::add)
        executor.runAll()
        dispatcher.runAll()

        assertEquals(listOf("encoded:new"), received)
    }

    @Test
    fun staleArtworkCannotReplaceNewerSnapshot() {
        val tracker = MediaSnapshotTracker(MutableMediaObserverStats())
        val artworkA = ArtworkKey(1, 1, 100, 100)
        val artworkB = ArtworkKey(2, 1, 100, 100)
        val initial = snapshot(artworkA)
        val initialDecision = tracker.evaluate(
            initial,
            forceReplay = false,
            artworkAvailable = false,
        )
        val newest = initial.copy(title = "Track B", artworkKey = artworkB)
        val newestDecision = tracker.evaluate(
            newest,
            forceReplay = false,
            artworkAvailable = false,
        )

        assertNull(
            tracker.artworkReady(initial.playbackId, initialDecision.generation, artworkA),
        )
        assertEquals(
            "updated",
            tracker.artworkReady(newest.playbackId, newestDecision.generation, artworkB)?.eventType,
        )
        assertEquals(newest, tracker.current(newest.playbackId)?.state)
    }

    @Test
    fun removedSessionRejectsArtworkCompletion() {
        val tracker = MediaSnapshotTracker(MutableMediaObserverStats())
        val artwork = ArtworkKey(1, 1, 100, 100)
        val candidate = snapshot(artwork)
        val decision = tracker.evaluate(candidate, false, artworkAvailable = false)

        tracker.remove(candidate.playbackId)

        assertNull(tracker.artworkReady(candidate.playbackId, decision.generation, artwork))
    }

    @Test
    fun closingPipelineInvalidatesEncodedCompletion() {
        val executor = QueuedExecutor()
        val dispatcher = QueuedDispatcher()
        val received = mutableListOf<String>()
        val pipeline = pipeline(executor, dispatcher) { source -> "encoded:$source" }
        pipeline.request("art", "source", "player", received::add)
        executor.runAll()
        assertEquals(1, dispatcher.size)

        pipeline.close()
        dispatcher.runAll()

        assertTrue(received.isEmpty())
        assertEquals(0, pipeline.cacheSize())
    }

    @Test
    fun restartedPipelineCannotReceiveOldLifecycleCompletion() {
        val executor = QueuedExecutor()
        val dispatcher = QueuedDispatcher()
        val received = mutableListOf<String>()
        val oldPipeline = pipeline(executor, dispatcher) { "old:$it" }
        oldPipeline.request("art", "source", "player", received::add)
        executor.runAll()
        oldPipeline.close()

        val newPipeline = pipeline(executor, dispatcher) { "new:$it" }
        newPipeline.request("art", "source", "player", received::add)
        executor.runAll()
        dispatcher.runAll()

        assertEquals(listOf("new:source"), received)
    }

    @Test
    fun artworkCacheHasDeterministicLruBound() {
        val cache = BoundedArtworkCache<String, String>(maxEntries = 2)
        cache.put("one", "1")
        cache.put("two", "2")
        assertEquals("1", cache.get("one"))

        cache.put("three", "3")

        assertEquals(2, cache.size())
        assertNull(cache.get("two"))
        assertEquals("1", cache.get("one"))
        assertEquals("3", cache.get("three"))
    }

    @Test
    fun temporaryMissingSessionDoesNotCauseLifecycleChurn() {
        val stats = MutableMediaObserverStats()
        val snapshots = MediaSnapshotTracker(stats)
        val missing = MissingSessionTracker(graceMs = 4_000L)
        val initial = snapshot(artworkKey = null)

        assertEquals("posted", snapshots.evaluate(initial, false, false).eventType)
        assertNull(snapshots.evaluate(initial, false, false).eventType)
        val changed = initial.copy(playbackState = "playing")
        assertEquals("updated", snapshots.evaluate(changed, false, false).eventType)
        assertEquals(MissingSessionDecision.NewlyMissing, missing.markMissing(initial.playbackId, 1_000L))
        assertEquals(MissingSessionDecision.Deferred, missing.markMissing(initial.playbackId, 4_999L))
        missing.markPresent(initial.playbackId)
        assertNull(snapshots.evaluate(changed, false, false).eventType)
        assertEquals(MissingSessionDecision.NewlyMissing, missing.markMissing(initial.playbackId, 6_000L))
        assertEquals(MissingSessionDecision.Remove, missing.markMissing(initial.playbackId, 10_000L))
        assertTrue(snapshots.remove(initial.playbackId))

        assertEquals(2L, stats.snapshot().snapshotsEmitted)
        assertFalse(snapshots.isPosted(initial.playbackId))
    }

    private fun pipeline(
        executor: QueuedExecutor,
        dispatcher: QueuedDispatcher,
        encoder: (String) -> String?,
    ): ArtworkPipeline<String, String, String> = ArtworkPipeline(
        cacheEntries = 2,
        executor = executor,
        completionDispatcher = dispatcher::dispatch,
        encoder = encoder,
    )

    private fun snapshot(artworkKey: ArtworkKey?): MediaSnapshotState = MediaSnapshotState(
        playbackId = "player",
        appId = "dev.player",
        appName = "Player",
        title = "Track A",
        artist = "Artist",
        album = "Album",
        playbackState = "paused",
        positionMs = 10_000L,
        durationMs = 180_000L,
        canPlay = true,
        canPause = true,
        canSkipNext = true,
        canSkipPrevious = true,
        canSeek = true,
        artworkKey = artworkKey,
    )

    private class QueuedExecutor : Executor {
        private val tasks = ArrayDeque<Runnable>()

        val size: Int
            get() = tasks.size

        override fun execute(command: Runnable) {
            tasks.addLast(command)
        }

        fun runAll() {
            while (tasks.isNotEmpty()) {
                tasks.removeFirst().run()
            }
        }
    }

    private class QueuedDispatcher {
        private val tasks = ArrayDeque<() -> Unit>()

        val size: Int
            get() = tasks.size

        fun dispatch(task: () -> Unit) {
            tasks.addLast(task)
        }

        fun runAll() {
            while (tasks.isNotEmpty()) {
                tasks.removeFirst().invoke()
            }
        }
    }
}
