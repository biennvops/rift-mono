package dev.rift.app

import java.util.concurrent.atomic.AtomicLong

internal data class ArtworkKey(
    val identity: Int,
    val generationId: Int,
    val width: Int,
    val height: Int,
)

internal data class MediaSnapshotState(
    val playbackId: String,
    val appId: String,
    val appName: String,
    val title: String?,
    val artist: String?,
    val album: String?,
    val playbackState: String,
    val positionMs: Long,
    val durationMs: Long?,
    val canPlay: Boolean,
    val canPause: Boolean,
    val canSkipNext: Boolean,
    val canSkipPrevious: Boolean,
    val canSeek: Boolean,
    val artworkKey: ArtworkKey?,
)

internal data class MediaSnapshotDecision(
    val eventType: String?,
    val generation: Long,
    val includeArtwork: Boolean,
    val requestArtwork: Boolean,
)

internal data class CurrentMediaSnapshot(
    val state: MediaSnapshotState,
    val generation: Long,
)

internal class MediaSnapshotTracker(
    private val stats: MutableMediaObserverStats,
) {
    private val currentById = HashMap<String, CurrentMediaSnapshot>()
    private val lastPublishedById = HashMap<String, MediaSnapshotState>()
    private val publishedArtworkById = HashMap<String, ArtworkKey>()
    private val postedIds = HashSet<String>()
    private var nextGeneration = 0L

    fun evaluate(
        candidate: MediaSnapshotState,
        forceReplay: Boolean,
        artworkAvailable: Boolean,
    ): MediaSnapshotDecision {
        stats.snapshotCandidates.incrementAndGet()
        val current = currentById[candidate.playbackId]
        val generation = if (current?.state == candidate) {
            current.generation
        } else {
            ++nextGeneration
        }
        currentById[candidate.playbackId] = CurrentMediaSnapshot(candidate, generation)

        val artworkKey = candidate.artworkKey
        val includeArtwork = artworkKey != null && artworkAvailable
        val isFirstPublication = candidate.playbackId !in postedIds
        val semanticChanged = lastPublishedById[candidate.playbackId] != candidate
        val encodedArtworkChanged = includeArtwork &&
            publishedArtworkById[candidate.playbackId] != artworkKey
        val shouldEmit = forceReplay || isFirstPublication || semanticChanged || encodedArtworkChanged

        if (!shouldEmit) {
            stats.duplicateSnapshotsSuppressed.incrementAndGet()
            return MediaSnapshotDecision(
                eventType = null,
                generation = generation,
                includeArtwork = false,
                requestArtwork = artworkKey != null &&
                    !artworkAvailable &&
                    publishedArtworkById[candidate.playbackId] != artworkKey,
            )
        }

        postedIds.add(candidate.playbackId)
        lastPublishedById[candidate.playbackId] = candidate
        if (includeArtwork) {
            publishedArtworkById[candidate.playbackId] = requireNotNull(artworkKey)
        } else {
            publishedArtworkById.remove(candidate.playbackId)
        }
        stats.snapshotsEmitted.incrementAndGet()
        return MediaSnapshotDecision(
            eventType = if (forceReplay || isFirstPublication) "posted" else "updated",
            generation = generation,
            includeArtwork = includeArtwork,
            requestArtwork = artworkKey != null && !artworkAvailable,
        )
    }

    fun artworkReady(
        playbackId: String,
        generation: Long,
        artworkKey: ArtworkKey,
    ): MediaSnapshotDecision? {
        val current = currentById[playbackId]
        if (
            current == null ||
            current.generation != generation ||
            current.state.artworkKey != artworkKey ||
            playbackId !in postedIds
        ) {
            return null
        }
        if (publishedArtworkById[playbackId] == artworkKey) {
            return null
        }

        lastPublishedById[playbackId] = current.state
        publishedArtworkById[playbackId] = artworkKey
        stats.snapshotsEmitted.incrementAndGet()
        return MediaSnapshotDecision(
            eventType = "updated",
            generation = generation,
            includeArtwork = true,
            requestArtwork = false,
        )
    }

    fun current(playbackId: String): CurrentMediaSnapshot? = currentById[playbackId]

    fun isPosted(playbackId: String): Boolean = playbackId in postedIds

    fun remove(playbackId: String): Boolean {
        currentById.remove(playbackId)
        lastPublishedById.remove(playbackId)
        publishedArtworkById.remove(playbackId)
        return postedIds.remove(playbackId)
    }

    fun clear() {
        currentById.clear()
        lastPublishedById.clear()
        publishedArtworkById.clear()
        postedIds.clear()
    }
}

internal class MediaAppLabelCache(
    private val resolver: (String) -> String,
    private val stats: MutableMediaObserverStats,
) {
    private val labelsByPackage = HashMap<String, String>()

    fun labelFor(packageName: String): String {
        labelsByPackage[packageName]?.let { label ->
            stats.appLabelCacheHits.incrementAndGet()
            return label
        }
        stats.appLabelLookups.incrementAndGet()
        return resolver(packageName).also { label -> labelsByPackage[packageName] = label }
    }

    fun clear() {
        labelsByPackage.clear()
    }
}

internal data class MediaObserverStats(
    val reconciliationPasses: Long,
    val snapshotCandidates: Long,
    val snapshotsEmitted: Long,
    val duplicateSnapshotsSuppressed: Long,
    val appLabelLookups: Long,
    val appLabelCacheHits: Long,
    val artworkRequests: Long,
    val artworkCacheHits: Long,
    val artworkEncodeStarted: Long,
    val artworkEncodeCompleted: Long,
    val artworkEncodeDiscardedStale: Long,
    val artworkBytesEncoded: Long,
)

internal class MutableMediaObserverStats {
    val reconciliationPasses = AtomicLong()
    val snapshotCandidates = AtomicLong()
    val snapshotsEmitted = AtomicLong()
    val duplicateSnapshotsSuppressed = AtomicLong()
    val appLabelLookups = AtomicLong()
    val appLabelCacheHits = AtomicLong()
    val artworkRequests = AtomicLong()
    val artworkCacheHits = AtomicLong()
    val artworkEncodeStarted = AtomicLong()
    val artworkEncodeCompleted = AtomicLong()
    val artworkEncodeDiscardedStale = AtomicLong()
    val artworkBytesEncoded = AtomicLong()

    fun snapshot(): MediaObserverStats = MediaObserverStats(
        reconciliationPasses = reconciliationPasses.get(),
        snapshotCandidates = snapshotCandidates.get(),
        snapshotsEmitted = snapshotsEmitted.get(),
        duplicateSnapshotsSuppressed = duplicateSnapshotsSuppressed.get(),
        appLabelLookups = appLabelLookups.get(),
        appLabelCacheHits = appLabelCacheHits.get(),
        artworkRequests = artworkRequests.get(),
        artworkCacheHits = artworkCacheHits.get(),
        artworkEncodeStarted = artworkEncodeStarted.get(),
        artworkEncodeCompleted = artworkEncodeCompleted.get(),
        artworkEncodeDiscardedStale = artworkEncodeDiscardedStale.get(),
        artworkBytesEncoded = artworkBytesEncoded.get(),
    )
}
