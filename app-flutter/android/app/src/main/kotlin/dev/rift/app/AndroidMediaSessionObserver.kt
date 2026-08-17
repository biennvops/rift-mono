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
    private val appLabelCache = MediaAppLabelCache(::resolveAppLabel, stats)
    private val mainHandler = Handler(Looper.getMainLooper())
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
    private val missingSinceById = HashMap<String, Long>()

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
            syncControllers(manager.getActiveSessions(component), forceReplay = true)
            return true
        }

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
            Log.w(tag, "Media session observation rejected", error)
            false
        }
    }

    fun stopObservation() {
        mainHandler.removeCallbacks(refreshRunnable)
        sessionsListener?.let { sessionManager?.removeOnActiveSessionsChangedListener(it) }
        sessionsListener = null
        sessionManager = null
        controllersById.keys.toList().forEach { removeController(it) }
        missingSinceById.clear()
        snapshotTracker.clear()
        appLabelCache.clear()
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
            missingSinceById.remove(id)
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
            val missingSince = missingSinceById.getOrPut(id) {
                Log.d(tag, "Deferring media session removal during active-session transition: $id")
                now
            }
            if (now - missingSince >= missingSessionGraceMs) {
                missingSinceById.remove(id)
                removeController(id)
            }
        }
    }

    private fun removeController(id: String) {
        missingSinceById.remove(id)
        val controller = controllersById.remove(id) ?: return
        callbacksById.remove(id)?.let { controller.unregisterCallback(it) }
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
        if (artwork != null) {
            stats.artworkRequests.incrementAndGet()
        }
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
            artworkKey = artwork?.let(::artworkKeyFor),
        )
        val decision = snapshotTracker.evaluate(
            candidate = candidate,
            forceReplay = forcePosted,
            artworkAvailable = artwork != null,
        )
        val eventType = decision.eventType ?: return
        val payload = mutableMapOf<String, Any?>(
            "eventType" to eventType,
            "playbackId" to candidate.playbackId,
            "sourcePlatform" to "android",
            "appId" to candidate.appId,
            "appName" to candidate.appName,
            "playbackState" to candidate.playbackState,
            "positionMs" to candidate.positionMs,
            "canPlay" to candidate.canPlay,
            "canPause" to candidate.canPause,
            "canSkipNext" to candidate.canSkipNext,
            "canSkipPrevious" to candidate.canSkipPrevious,
            "canSeek" to candidate.canSeek,
            "updatedAt" to isoNow(),
        )
        candidate.title?.let { payload["title"] = it }
        candidate.artist?.let { payload["artist"] = it }
        candidate.album?.let { payload["album"] = it }
        candidate.durationMs?.let { payload["durationMs"] = it }
        if (decision.includeArtwork && artwork != null) {
            encodeArtwork(artwork)?.let { payload["artwork"] = it }
        }

        eventSink?.success(payload)
        payloadCallback?.invoke(payload)
    }

    private fun artworkBitmap(metadata: MediaMetadata?): Bitmap? =
        metadata?.getBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART)
            ?: metadata?.getBitmap(MediaMetadata.METADATA_KEY_ART)

    private fun artworkKeyFor(bitmap: Bitmap): ArtworkKey = ArtworkKey(
        identity = System.identityHashCode(bitmap),
        generationId = bitmap.generationId,
        width = bitmap.width,
        height = bitmap.height,
    )

    private fun encodeArtwork(bitmap: Bitmap): Map<String, Any?>? {
        stats.artworkEncodeStarted.incrementAndGet()
        val scaled = if (bitmap.width > artworkMaxDimension || bitmap.height > artworkMaxDimension) {
            val ratio = artworkMaxDimension.toFloat() / maxOf(bitmap.width, bitmap.height)
            Bitmap.createScaledBitmap(
                bitmap,
                (bitmap.width * ratio).toInt().coerceAtLeast(1),
                (bitmap.height * ratio).toInt().coerceAtLeast(1),
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
        val digest = MessageDigest.getInstance("SHA-256").digest(bytes)
            .joinToString(separator = "") { byte ->
                "%02x".format(byte.toInt() and 0xff)
            }
        stats.artworkEncodeCompleted.incrementAndGet()
        stats.artworkBytesEncoded.addAndGet(bytes.size.toLong())
        return mapOf(
            "mimeType" to "image/png",
            "dataBase64" to Base64.encodeToString(bytes, Base64.NO_WRAP),
            "byteSize" to bytes.size,
            "sha256" to digest,
        )
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

    private fun isoNow(): String {
        val format = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US)
        format.timeZone = TimeZone.getTimeZone("UTC")
        return format.format(Date())
    }
}
