package dev.rift.app

import android.content.ComponentName
import android.content.Context
import android.graphics.Bitmap
import android.media.MediaMetadata
import android.media.session.MediaController
import android.media.session.MediaSessionManager
import android.media.session.PlaybackState
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Base64
import android.util.Log
import io.flutter.plugin.common.EventChannel
import java.io.ByteArrayOutputStream
import java.security.MessageDigest
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit

private data class MediaArtworkSource(
    val key: ArtworkKey,
    val bitmap: Bitmap,
    val generationId: Int,
    val width: Int,
    val height: Int,
)

/**
 * Publishes local media sessions (any app with a MediaSession) to Flutter.
 *
 * Requires notification listener access: `MediaSessionManager.getActiveSessions`
 * is gated on the same permission as `RiftNotificationListenerService`.
 */
class AndroidMediaSessionObserver(
    private val context: Context,
    private val payloadCallback: ((Map<String, Any?>) -> Unit)? = null,
) {
    companion object {
        private const val tag = "RiftMediaObserver"
        private const val artworkMaxDimension = 256
        private const val artworkCacheEntries = 12
        private const val artworkQueueCapacity = 12
        private const val missingSessionGraceMs = 4_000L

        internal fun canPlay(actions: Long): Boolean =
            actions and (PlaybackState.ACTION_PLAY or PlaybackState.ACTION_PLAY_PAUSE) != 0L

        internal fun canPause(actions: Long): Boolean =
            actions and (PlaybackState.ACTION_PAUSE or PlaybackState.ACTION_PLAY_PAUSE) != 0L

        internal fun shouldObservePackage(packageName: String, ownPackageName: String): Boolean =
            packageName != ownPackageName
    }

    private val stats = MutableMediaObserverStats()
    private val snapshotTracker = MediaSnapshotTracker(stats)
    private val artworkKeyResolver = ArtworkKeyResolver()
    private val appLabelCache = MediaAppLabelCache(::resolveAppLabel, stats)
    private val timestampFormat = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US).apply {
        timeZone = TimeZone.getTimeZone("UTC")
    }
    private val mainHandler = Handler(Looper.getMainLooper())
    private var observationGeneration = 0L
    private var artworkExecutor: ThreadPoolExecutor? = null
    private var artworkPipeline: ArtworkPipeline<ArtworkKey, MediaArtworkSource, EncodedMediaArtwork>? = null
    private val refreshRunnable = object : Runnable {
        override fun run() {
            val manager = sessionManager
            val listener = sessionsListener
            if (manager != null && listener != null) {
                try {
                    syncControllers(
                        manager.getActiveSessions(
                            ComponentName(context, RiftNotificationListenerService::class.java),
                        ),
                    )
                } catch (error: SecurityException) {
                    Log.w(tag, "Media session refresh rejected", error)
                }
                mainHandler.postDelayed(this, 2_000L)
            }
        }
    }
    private var eventSink: EventChannel.EventSink? = null
    private var sessionManager: MediaSessionManager? = null
    private var sessionsListener: MediaSessionManager.OnActiveSessionsChangedListener? = null
    private val controllersById = LinkedHashMap<String, MediaController>()
    private val callbacksById = HashMap<String, MediaController.Callback>()
    private val missingSessions = MissingSessionTracker(missingSessionGraceMs)

    fun setEventSink(sink: EventChannel.EventSink?) {
        eventSink = sink
    }

    fun startObservation(): Boolean {
        if (!hasNotificationListenerAccess()) {
            Log.w(tag, "Notification listener access not granted; media observation unavailable")
            return false
        }
        val component = ComponentName(context, RiftNotificationListenerService::class.java)
        if (sessionsListener != null) {
            val manager = sessionManager ?: return false
            if (artworkPipeline == null) {
                observationGeneration += 1
                startArtworkPipeline()
            }
            syncControllers(manager.getActiveSessions(component), forceReplay = true)
            return true
        }

        observationGeneration += 1
        startArtworkPipeline()
        val manager =
            context.getSystemService(Context.MEDIA_SESSION_SERVICE) as MediaSessionManager
        val listener = MediaSessionManager.OnActiveSessionsChangedListener { controllers ->
            syncControllers(controllers ?: emptyList())
        }
        return try {
            manager.addOnActiveSessionsChangedListener(listener, component, mainHandler)
            sessionManager = manager
            sessionsListener = listener
            syncControllers(manager.getActiveSessions(component))
            mainHandler.removeCallbacks(refreshRunnable)
            mainHandler.postDelayed(refreshRunnable, 2_000L)
            true
        } catch (error: SecurityException) {
            observationGeneration += 1
            stopArtworkPipeline()
            try {
                manager.removeOnActiveSessionsChangedListener(listener)
            } catch (_: SecurityException) {
                // Permission can be revoked between registration and cleanup.
            }
            sessionsListener = null
            sessionManager = null
            Log.w(tag, "Media session observation rejected", error)
            false
        }
    }

    fun stopObservation() {
        mainHandler.removeCallbacks(refreshRunnable)
        observationGeneration += 1
        stopArtworkPipeline()
        sessionsListener?.let { listener ->
            try {
                sessionManager?.removeOnActiveSessionsChangedListener(listener)
            } catch (error: SecurityException) {
                Log.w(tag, "Media session listener cleanup rejected", error)
            }
        }
        sessionsListener = null
        sessionManager = null
        controllersById.keys.toList().forEach { removeController(it) }
        missingSessions.clear()
        snapshotTracker.clear()
        artworkKeyResolver.clear()
        appLabelCache.clear()
        Log.d(tag, "Media observer stats: ${stats.snapshot()}")
    }

    internal fun statsSnapshot(): MediaObserverStats = stats.snapshot()

    fun performAction(playbackId: String, action: String, positionMs: Long?): Map<String, Any?> {
        val controller = controllersById[playbackId]
            ?: return mapOf(
                "success" to false,
                "failureReason" to "CapabilityUnavailable",
                "message" to "Media session is no longer active.",
            )
        val transport = controller.transportControls
        return try {
            when (action) {
                "play" -> transport.play()
                "pause" -> transport.pause()
                "togglePlayPause" -> {
                    if (controller.playbackState?.state == PlaybackState.STATE_PLAYING) {
                        transport.pause()
                    } else {
                        transport.play()
                    }
                }
                "next" -> transport.skipToNext()
                "previous" -> transport.skipToPrevious()
                "seek" -> {
                    if (positionMs == null) {
                        return mapOf(
                            "success" to false,
                            "failureReason" to "PeerRejected",
                            "message" to "seek requires positionMs.",
                        )
                    }
                    transport.seekTo(positionMs)
                }
                else -> return mapOf(
                    "success" to false,
                    "failureReason" to "PeerRejected",
                    "message" to "Unsupported action: $action",
                )
            }
            mapOf("success" to true)
        } catch (error: Exception) {
            mapOf(
                "success" to false,
                "failureReason" to "PeerRejected",
                "message" to (error.message ?: error.javaClass.simpleName),
            )
        }
    }

    private fun hasNotificationListenerAccess(): Boolean {
        val enabled = android.provider.Settings.Secure.getString(
            context.contentResolver,
            "enabled_notification_listeners",
        ) ?: return false
        return enabled.contains(context.packageName)
    }

    private fun syncControllers(
        controllers: List<MediaController>,
        forceReplay: Boolean = false,
    ) {
        stats.reconciliationPasses.incrementAndGet()
        val nextIds = HashSet<String>()
        for (controller in controllers) {
            // Never observe our own sessions: RemoteMediaPlaybackManager
            // creates a MediaSessionCompat to display *remote* playback, and
            // republishing it would echo peers' media back at them in a loop.
            if (!shouldObservePackage(controller.packageName, context.packageName)) {
                continue
            }
            val id = playbackIdFor(controller)
            nextIds.add(id)
            missingSessions.markPresent(id)
            if (!controllersById.containsKey(id)) {
                val callback = object : MediaController.Callback() {
                    override fun onPlaybackStateChanged(state: PlaybackState?) {
                        emitSnapshot(id)
                    }

                    override fun onMetadataChanged(metadata: MediaMetadata?) {
                        emitSnapshot(id)
                    }

                    override fun onSessionDestroyed() {
                        removeController(id)
                    }
                }
                controller.registerCallback(callback, mainHandler)
                controllersById[id] = controller
                callbacksById[id] = callback
            }
            emitSnapshot(id, forcePosted = forceReplay)
        }

        val now = SystemClock.elapsedRealtime()
        val removed = controllersById.keys.filter { it !in nextIds }
        for (id in removed) {
            when (missingSessions.markMissing(id, now)) {
                MissingSessionDecision.NewlyMissing ->
                    Log.d(tag, "Deferring media session removal during active-session transition: $id")
                MissingSessionDecision.Deferred -> Unit
                MissingSessionDecision.Remove -> removeController(id)
            }
        }
    }

    private fun removeController(id: String) {
        missingSessions.remove(id)
        val controller = controllersById.remove(id) ?: return
        callbacksById.remove(id)?.let { controller.unregisterCallback(it) }
        artworkPipeline?.removeRequester(id)
        artworkKeyResolver.remove(id)
        if (snapshotTracker.remove(id)) {
            val payload = mapOf(
                "eventType" to "removed",
                "playbackId" to id,
                "removedAt" to isoNow(),
            )
            eventSink?.success(payload)
            payloadCallback?.invoke(payload)
        }
    }

    private fun emitSnapshot(id: String, forcePosted: Boolean = false) {
        val controller = controllersById[id] ?: return
        val playback = controller.playbackState ?: return
        val playbackState = when (playback.state) {
            PlaybackState.STATE_PLAYING -> "playing"
            PlaybackState.STATE_PAUSED -> "paused"
            PlaybackState.STATE_BUFFERING, PlaybackState.STATE_CONNECTING -> "buffering"
            PlaybackState.STATE_STOPPED, PlaybackState.STATE_NONE -> "stopped"
            else -> return // transient error/skipping states: skip the update
        }
        val metadata = controller.metadata
        if (playbackState == "stopped" && !snapshotTracker.isPosted(id)) {
            return
        }

        val artwork = artworkBitmap(metadata)
        val artworkSource = artwork?.let { bitmap -> artworkSourceFor(id, metadata, bitmap) }
        val artworkKey = artworkSource?.key
        val pipeline = artworkPipeline
        pipeline?.retainRequesterForKey(id, artworkKey)
        val artworkLookup = artworkKey?.let { key -> pipeline?.lookup(key) }
        val actions = playback.actions
        val candidate = MediaSnapshotState(
            playbackId = id,
            appId = controller.packageName,
            appName = appLabelCache.labelFor(controller.packageName),
            title = metadata?.getString(MediaMetadata.METADATA_KEY_TITLE),
            artist = metadata?.getString(MediaMetadata.METADATA_KEY_ARTIST),
            album = metadata?.getString(MediaMetadata.METADATA_KEY_ALBUM),
            playbackState = playbackState,
            positionMs = playback.position.coerceAtLeast(0L),
            durationMs = metadata?.getLong(MediaMetadata.METADATA_KEY_DURATION)?.takeIf { it > 0L },
            canPlay = canPlay(actions),
            canPause = canPause(actions),
            canSkipNext = actions and PlaybackState.ACTION_SKIP_TO_NEXT != 0L,
            canSkipPrevious = actions and PlaybackState.ACTION_SKIP_TO_PREVIOUS != 0L,
            canSeek = actions and PlaybackState.ACTION_SEEK_TO != 0L,
            artworkKey = artworkKey,
        )
        val decision = snapshotTracker.evaluate(
            candidate = candidate,
            forceReplay = forcePosted,
            artworkAvailable = artworkLookup?.value != null,
        )
        decision.eventType?.let { eventType ->
            publishSnapshot(
                state = candidate,
                eventType = eventType,
                artwork = if (decision.includeArtwork) artworkLookup?.value else null,
            )
        }

        if (
            decision.requestArtwork &&
            artworkSource != null &&
            artworkKey != null &&
            artworkLookup?.isCached != true &&
            pipeline != null
        ) {
            val requestedObservationGeneration = observationGeneration
            pipeline.request(
                key = artworkKey,
                source = artworkSource,
                requesterId = id,
            ) { encoded ->
                acceptArtwork(
                    observationGeneration = requestedObservationGeneration,
                    playbackId = id,
                    snapshotGeneration = decision.generation,
                    artworkKey = artworkKey,
                    artwork = encoded,
                )
            }
        }
    }

    private fun publishSnapshot(
        state: MediaSnapshotState,
        eventType: String,
        artwork: EncodedMediaArtwork?,
    ) {
        val payload = mutableMapOf<String, Any?>(
            "eventType" to eventType,
            "playbackId" to state.playbackId,
            "sourcePlatform" to "android",
            "appId" to state.appId,
            "appName" to state.appName,
            "playbackState" to state.playbackState,
            "positionMs" to state.positionMs,
            "canPlay" to state.canPlay,
            "canPause" to state.canPause,
            "canSkipNext" to state.canSkipNext,
            "canSkipPrevious" to state.canSkipPrevious,
            "canSeek" to state.canSeek,
            "updatedAt" to isoNow(),
        )
        state.title?.let { payload["title"] = it }
        state.artist?.let { payload["artist"] = it }
        state.album?.let { payload["album"] = it }
        state.durationMs?.let { payload["durationMs"] = it }
        artwork?.let { payload["artwork"] = it.asMap() }

        eventSink?.success(payload)
        payloadCallback?.invoke(payload)
    }

    private fun acceptArtwork(
        observationGeneration: Long,
        playbackId: String,
        snapshotGeneration: Long,
        artworkKey: ArtworkKey,
        artwork: EncodedMediaArtwork,
    ) {
        if (
            observationGeneration != this.observationGeneration ||
            playbackId !in controllersById
        ) {
            stats.artworkEncodeDiscardedStale.incrementAndGet()
            return
        }
        val decision = snapshotTracker.artworkReady(
            playbackId = playbackId,
            generation = snapshotGeneration,
            artworkKey = artworkKey,
        )
        val current = snapshotTracker.current(playbackId)
        if (decision?.eventType == null || current == null) {
            stats.artworkEncodeDiscardedStale.incrementAndGet()
            return
        }
        publishSnapshot(current.state, decision.eventType, artwork)
    }

    private fun artworkBitmap(metadata: MediaMetadata?): Bitmap? =
        metadata?.getBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART)
            ?: metadata?.getBitmap(MediaMetadata.METADATA_KEY_ART)

    private fun artworkSourceFor(
        playbackId: String,
        metadata: MediaMetadata?,
        bitmap: Bitmap,
    ): MediaArtworkSource? {
        if (bitmap.isRecycled) return null
        val generationId = bitmap.generationId
        val width = bitmap.width
        val height = bitmap.height
        val key = artworkKeyResolver.resolve(
            playbackId = playbackId,
            bitmap = bitmap,
            bitmapIdentity = System.identityHashCode(bitmap),
            generationId = generationId,
            width = width,
            height = height,
            semanticIdentity = artworkSemanticIdentity(metadata),
        )
        return MediaArtworkSource(
            key = key,
            bitmap = bitmap,
            generationId = generationId,
            width = width,
            height = height,
        )
    }

    private fun artworkSemanticIdentity(metadata: MediaMetadata?): ArtworkSemanticIdentity? {
        if (metadata == null) return null
        val uri = metadata.getString(MediaMetadata.METADATA_KEY_ART_URI)?.takeIf { it.isNotBlank() }
            ?: metadata.getString(MediaMetadata.METADATA_KEY_ALBUM_ART_URI)?.takeIf { it.isNotBlank() }
            ?: metadata.getString(MediaMetadata.METADATA_KEY_DISPLAY_ICON_URI)?.takeIf { it.isNotBlank() }
        val mediaId = metadata.getString(MediaMetadata.METADATA_KEY_MEDIA_ID)?.takeIf { it.isNotBlank() }
        val title = metadata.getString(MediaMetadata.METADATA_KEY_TITLE)
        val artist = metadata.getString(MediaMetadata.METADATA_KEY_ARTIST)
        val album = metadata.getString(MediaMetadata.METADATA_KEY_ALBUM)
        val duration = metadata.getLong(MediaMetadata.METADATA_KEY_DURATION).takeIf { it > 0L }
        return artworkSemanticIdentity(
            uri = uri,
            mediaId = mediaId,
            title = title,
            artist = artist,
            album = album,
            durationMs = duration,
        )
    }

    private fun encodeArtwork(source: MediaArtworkSource): EncodedMediaArtwork? {
        val bitmap = source.bitmap
        if (!bitmapMatchesSource(bitmap, source)) return null

        val scaled = if (source.width > artworkMaxDimension || source.height > artworkMaxDimension) {
            val ratio = artworkMaxDimension.toFloat() / maxOf(source.width, source.height)
            Bitmap.createScaledBitmap(
                bitmap,
                (source.width * ratio).toInt().coerceAtLeast(1),
                (source.height * ratio).toInt().coerceAtLeast(1),
                true,
            )
        } else {
            bitmap
        }
        val bytes = try {
            val output = ByteArrayOutputStream()
            if (!scaled.compress(Bitmap.CompressFormat.PNG, 90, output)) {
                return null
            }
            output.toByteArray()
        } finally {
            if (scaled !== bitmap) {
                scaled.recycle()
            }
        }
        if (!bitmapMatchesSource(bitmap, source)) return null

        val digest = MessageDigest.getInstance("SHA-256").digest(bytes)
            .joinToString(separator = "") { byte ->
                "%02x".format(byte.toInt() and 0xff)
            }
        return EncodedMediaArtwork(
            mimeType = "image/png",
            dataBase64 = Base64.encodeToString(bytes, Base64.NO_WRAP),
            byteSize = bytes.size,
            sha256 = digest,
        )
    }

    private fun bitmapMatchesSource(bitmap: Bitmap, source: MediaArtworkSource): Boolean =
        !bitmap.isRecycled &&
            bitmap.generationId == source.generationId &&
            bitmap.width == source.width &&
            bitmap.height == source.height

    private fun startArtworkPipeline() {
        check(artworkPipeline == null)
        val executor = ThreadPoolExecutor(
            1,
            1,
            0L,
            TimeUnit.MILLISECONDS,
            ArrayBlockingQueue<Runnable>(artworkQueueCapacity),
            { runnable -> Thread(runnable, "RiftMediaArtwork") },
        )
        artworkExecutor = executor
        artworkPipeline = ArtworkPipeline(
            cacheEntries = artworkCacheEntries,
            executor = executor,
            completionDispatcher = { completion -> mainHandler.post { completion() } },
            encoder = ::encodeArtwork,
            onRequest = { stats.artworkRequests.incrementAndGet() },
            onCacheHit = { stats.artworkCacheHits.incrementAndGet() },
            onEncodeStarted = { stats.artworkEncodeStarted.incrementAndGet() },
            onEncodeCompleted = { artwork ->
                stats.artworkEncodeCompleted.incrementAndGet()
                stats.artworkBytesEncoded.addAndGet(artwork.byteSize.toLong())
            },
            onDiscarded = { stats.artworkEncodeDiscardedStale.incrementAndGet() },
        )
    }

    private fun stopArtworkPipeline() {
        artworkPipeline?.close()
        artworkPipeline = null
        artworkExecutor?.shutdownNow()
        artworkExecutor = null
    }

    private fun resolveAppLabel(packageName: String): String {
        return try {
            val info = context.packageManager.getApplicationInfo(packageName, 0)
            context.packageManager.getApplicationLabel(info).toString()
        } catch (_: Exception) {
            packageName
        }
    }

    private fun playbackIdFor(controller: MediaController): String =
        "${controller.packageName}#${controller.sessionToken.hashCode()}"

    private fun isoNow(): String = timestampFormat.format(Date())
}
