package com.example.app_flutter

import android.content.ComponentName
import android.content.Context
import android.graphics.Bitmap
import android.media.MediaMetadata
import android.media.session.MediaController
import android.media.session.MediaSessionManager
import android.media.session.PlaybackState
import android.os.Handler
import android.os.Looper
import android.util.Base64
import android.util.Log
import io.flutter.plugin.common.EventChannel
import java.io.ByteArrayOutputStream
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
class AndroidMediaSessionObserver(private val context: Context) {
    companion object {
        private const val tag = "RiftMediaObserver"
        private const val artworkMaxDimension = 256
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private var eventSink: EventChannel.EventSink? = null
    private var sessionManager: MediaSessionManager? = null
    private var sessionsListener: MediaSessionManager.OnActiveSessionsChangedListener? = null
    private val controllersById = LinkedHashMap<String, MediaController>()
    private val callbacksById = HashMap<String, MediaController.Callback>()
    private val postedIds = HashSet<String>()

    fun setEventSink(sink: EventChannel.EventSink?) {
        eventSink = sink
    }

    fun startObservation(): Boolean {
        if (!hasNotificationListenerAccess()) {
            Log.w(tag, "Notification listener access not granted; media observation unavailable")
            return false
        }
        if (sessionsListener != null) {
            return true
        }

        val manager =
            context.getSystemService(Context.MEDIA_SESSION_SERVICE) as MediaSessionManager
        val component = ComponentName(context, RiftNotificationListenerService::class.java)
        val listener = MediaSessionManager.OnActiveSessionsChangedListener { controllers ->
            syncControllers(controllers ?: emptyList())
        }
        return try {
            manager.addOnActiveSessionsChangedListener(listener, component, mainHandler)
            sessionManager = manager
            sessionsListener = listener
            syncControllers(manager.getActiveSessions(component))
            true
        } catch (error: SecurityException) {
            Log.w(tag, "Media session observation rejected", error)
            false
        }
    }

    fun stopObservation() {
        sessionsListener?.let { sessionManager?.removeOnActiveSessionsChangedListener(it) }
        sessionsListener = null
        sessionManager = null
        syncControllers(emptyList())
    }

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
                "skipNext" -> transport.skipToNext()
                "skipPrevious" -> transport.skipToPrevious()
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

    private fun syncControllers(controllers: List<MediaController>) {
        val nextIds = HashSet<String>()
        for (controller in controllers) {
            // Never observe our own sessions: RemoteMediaPlaybackManager
            // creates a MediaSessionCompat to display *remote* playback, and
            // republishing it would echo peers' media back at them in a loop.
            if (controller.packageName == context.packageName) {
                continue
            }
            val id = playbackIdFor(controller)
            nextIds.add(id)
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
            emitSnapshot(id)
        }

        val removed = controllersById.keys.filter { it !in nextIds }
        for (id in removed) {
            removeController(id)
        }
    }

    private fun removeController(id: String) {
        val controller = controllersById.remove(id) ?: return
        callbacksById.remove(id)?.let { controller.unregisterCallback(it) }
        if (postedIds.remove(id)) {
            eventSink?.success(
                mapOf(
                    "eventType" to "removed",
                    "playbackId" to id,
                    "removedAt" to isoNow(),
                ),
            )
        }
    }

    private fun emitSnapshot(id: String) {
        val controller = controllersById[id] ?: return
        val state = controller.playbackState ?: return
        val playbackState = when (state.state) {
            PlaybackState.STATE_PLAYING -> "playing"
            PlaybackState.STATE_PAUSED -> "paused"
            PlaybackState.STATE_BUFFERING, PlaybackState.STATE_CONNECTING -> "buffering"
            PlaybackState.STATE_STOPPED, PlaybackState.STATE_NONE -> "stopped"
            else -> return // transient error/skipping states: skip the update
        }
        // Sessions that have never published metadata are not useful remotely.
        val metadata = controller.metadata
        if (playbackState == "stopped" && !postedIds.contains(id)) {
            return
        }

        val actions = state.actions
        val payload = mutableMapOf<String, Any?>(
            "eventType" to if (postedIds.contains(id)) "updated" else "posted",
            "playbackId" to id,
            "sourcePlatform" to "android",
            "appId" to controller.packageName,
            "appName" to appLabelFor(controller.packageName),
            "playbackState" to playbackState,
            "positionMs" to state.position.coerceAtLeast(0L),
            "canPlay" to (actions and PlaybackState.ACTION_PLAY != 0L),
            "canPause" to (actions and PlaybackState.ACTION_PAUSE != 0L),
            "canSkipNext" to (actions and PlaybackState.ACTION_SKIP_TO_NEXT != 0L),
            "canSkipPrevious" to (actions and PlaybackState.ACTION_SKIP_TO_PREVIOUS != 0L),
            "canSeek" to (actions and PlaybackState.ACTION_SEEK_TO != 0L),
            "updatedAt" to isoNow(),
        )
        if (metadata != null) {
            metadata.getString(MediaMetadata.METADATA_KEY_TITLE)?.let { payload["title"] = it }
            metadata.getString(MediaMetadata.METADATA_KEY_ARTIST)?.let { payload["artist"] = it }
            metadata.getString(MediaMetadata.METADATA_KEY_ALBUM)?.let { payload["album"] = it }
            val duration = metadata.getLong(MediaMetadata.METADATA_KEY_DURATION)
            if (duration > 0) {
                payload["durationMs"] = duration
            }
            encodeArtwork(metadata)?.let { payload["artwork"] = it }
        }

        postedIds.add(id)
        eventSink?.success(payload)
    }

    private fun encodeArtwork(metadata: MediaMetadata): Map<String, Any?>? {
        val bitmap = metadata.getBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART)
            ?: metadata.getBitmap(MediaMetadata.METADATA_KEY_ART)
            ?: return null
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
        val output = ByteArrayOutputStream()
        scaled.compress(Bitmap.CompressFormat.PNG, 90, output)
        return mapOf(
            "mimeType" to "image/png",
            "dataBase64" to Base64.encodeToString(output.toByteArray(), Base64.NO_WRAP),
        )
    }

    private fun appLabelFor(packageName: String): String {
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
