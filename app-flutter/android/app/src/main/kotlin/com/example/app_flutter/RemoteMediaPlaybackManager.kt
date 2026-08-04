package com.example.app_flutter

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Build
import android.support.v4.media.MediaMetadataCompat
import android.support.v4.media.session.MediaSessionCompat
import android.support.v4.media.session.PlaybackStateCompat
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.media.app.NotificationCompat.MediaStyle
import android.util.Base64

class RemoteMediaPlaybackManager(
    private val context: Context,
    private val launchIntentFactory: () -> Intent,
    private val actionCallback: (Map<String, Any?>) -> Unit,
) {
    companion object {
        const val notificationChannelId = "rift.media_playback"
        const val notificationChannelName = "Rift media playback"
        private const val notificationId = 4109
        private const val actionIntent = "com.example.app_flutter.MEDIA_PLAYBACK_ACTION"
        private const val extraSourceDeviceId = "sourceDeviceId"
        private const val extraPlaybackId = "playbackId"
        private const val extraAction = "action"
        private const val extraPositionMs = "positionMs"
    }

    private val mediaSession =
        MediaSessionCompat(context, "RiftRemoteMediaPlayback").apply {
            isActive = false
        }
    private var currentPlayback: Map<String, Any?>? = null
    private var receiverRegistered = false

    private val receiver =
        object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                val sourceDeviceId = intent?.getStringExtra(extraSourceDeviceId) ?: return
                val playbackId = intent.getStringExtra(extraPlaybackId) ?: return
                val action = intent.getStringExtra(extraAction) ?: return
                val payload = linkedMapOf<String, Any?>(
                    "sourceDeviceId" to sourceDeviceId,
                    "playbackId" to playbackId,
                    "action" to action,
                )
                if (intent.hasExtra(extraPositionMs)) {
                    payload["positionMs"] = intent.getLongExtra(extraPositionMs, 0L)
                }
                actionCallback(payload)
            }
        }

    init {
        mediaSession.setCallback(
            object : MediaSessionCompat.Callback() {
                override fun onPlay() = dispatchCurrentPlaybackAction("play")

                override fun onPause() = dispatchCurrentPlaybackAction("pause")

                override fun onSkipToNext() = dispatchCurrentPlaybackAction("next")

                override fun onSkipToPrevious() = dispatchCurrentPlaybackAction("previous")

                override fun onSeekTo(positionMs: Long) =
                    dispatchCurrentPlaybackAction("seek", positionMs)
            },
        )
    }

    private fun dispatchCurrentPlaybackAction(action: String, positionMs: Long? = null) {
        val playback = currentPlayback ?: return
        val sourceDeviceId = playback["sourceDeviceId"]?.toString()?.takeIf { it.isNotBlank() } ?: return
        val playbackId = playback["playbackId"]?.toString()?.takeIf { it.isNotBlank() } ?: return
        actionCallback(
            linkedMapOf<String, Any?>(
                "sourceDeviceId" to sourceDeviceId,
                "playbackId" to playbackId,
                "action" to action,
                "positionMs" to positionMs,
            ).filterValues { it != null },
        )
    }

    fun start() {
        if (receiverRegistered) {
            return
        }
        val filter = IntentFilter(actionIntent)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            context.registerReceiver(receiver, filter)
        }
        receiverRegistered = true
    }

    fun stop() {
        clear()
        if (!receiverRegistered) {
            return
        }
        context.unregisterReceiver(receiver)
        receiverRegistered = false
        mediaSession.release()
    }

    fun show(playback: Map<String, Any?>): Boolean {
        currentPlayback = LinkedHashMap(playback)
        mediaSession.isActive = true
        mediaSession.setMetadata(buildMetadata(playback))
        mediaSession.setPlaybackState(buildPlaybackState(playback))

        val artwork = decodeArtwork(playback)
        val title = playback["title"]?.toString()?.takeIf { it.isNotBlank() }
            ?: playback["appName"]?.toString()?.takeIf { it.isNotBlank() }
            ?: "Remote playback"
        val subtitle = listOfNotNull(
            playback["artist"]?.toString()?.takeIf { it.isNotBlank() },
            playback["album"]?.toString()?.takeIf { it.isNotBlank() },
            playback["sourceDeviceId"]?.toString()?.takeIf { it.isNotBlank() },
        ).joinToString(" • ")
        val contentIntent =
            PendingIntent.getActivity(
                context,
                notificationId,
                launchIntentFactory(),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        val style =
            MediaStyle()
                .setMediaSession(mediaSession.sessionToken)
                .setShowActionsInCompactView(*compactActionIndexes(playback))

        val builder =
            NotificationCompat.Builder(context, notificationChannelId)
                .setSmallIcon(R.mipmap.ic_launcher)
                .setContentTitle(title)
                .setContentText(subtitle.ifBlank { playback["appName"]?.toString() ?: "Rift" })
                .setStyle(style)
                .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
                .setOngoing(playback["playbackState"]?.toString() == "playing")
                .setOnlyAlertOnce(true)
                .setContentIntent(contentIntent)
                .setDeleteIntent(buildActionIntent(playback, "dismiss"))
        if (artwork != null) {
            builder.setLargeIcon(artwork)
        }

        addActions(builder, playback)

        return try {
            NotificationManagerCompat.from(context).notify(notificationId, builder.build())
            true
        } catch (_: SecurityException) {
            false
        }
    }

    fun clear(): Boolean {
        currentPlayback = null
        mediaSession.isActive = false
        NotificationManagerCompat.from(context).cancel(notificationId)
        return true
    }

    private fun addActions(builder: NotificationCompat.Builder, playback: Map<String, Any?>) {
        val playbackId = playback["playbackId"]?.toString() ?: return
        if (playback["canSkipPrevious"] == true) {
            builder.addAction(
                NotificationCompat.Action(
                    0,
                    "Previous",
                    buildActionIntent(playback, "previous"),
                ),
            )
        }

        val isPlaying = playback["playbackState"]?.toString() == "playing"
        if (isPlaying && playback["canPause"] == true) {
            builder.addAction(
                NotificationCompat.Action(
                    0,
                    "Pause",
                    buildActionIntent(playback, "pause"),
                ),
            )
        } else if (!isPlaying && playback["canPlay"] == true) {
            builder.addAction(
                NotificationCompat.Action(
                    0,
                    "Play",
                    buildActionIntent(playback, "play"),
                ),
            )
        }

        if (playback["canSkipNext"] == true) {
            builder.addAction(
                NotificationCompat.Action(
                    0,
                    "Next",
                    buildActionIntent(playback, "next"),
                ),
            )
        }
    }

    private fun compactActionIndexes(playback: Map<String, Any?>): IntArray {
        val indexes = mutableListOf<Int>()
        var index = 0
        if (playback["canSkipPrevious"] == true) {
            indexes += index
            index += 1
        }
        val isPlaying = playback["playbackState"]?.toString() == "playing"
        if ((isPlaying && playback["canPause"] == true) || (!isPlaying && playback["canPlay"] == true)) {
            indexes += index
            index += 1
        }
        if (playback["canSkipNext"] == true) {
            indexes += index
        }
        return indexes.toIntArray()
    }

    private fun buildActionIntent(playback: Map<String, Any?>, action: String): PendingIntent {
        val sourceDeviceId = playback["sourceDeviceId"]?.toString().orEmpty()
        val playbackId = playback["playbackId"]?.toString().orEmpty()
        val intent =
            Intent(actionIntent).apply {
                setPackage(context.packageName)
                putExtra(extraSourceDeviceId, sourceDeviceId)
                putExtra(extraPlaybackId, playbackId)
                putExtra(extraAction, action)
            }
        return PendingIntent.getBroadcast(
            context,
            "$sourceDeviceId:$playbackId:$action".hashCode(),
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun buildMetadata(playback: Map<String, Any?>): MediaMetadataCompat {
        val builder =
            MediaMetadataCompat.Builder()
                .putString(MediaMetadataCompat.METADATA_KEY_TITLE, playback["title"]?.toString())
                .putString(MediaMetadataCompat.METADATA_KEY_ARTIST, playback["artist"]?.toString())
                .putString(MediaMetadataCompat.METADATA_KEY_ALBUM, playback["album"]?.toString())
                .putString(MediaMetadataCompat.METADATA_KEY_DISPLAY_TITLE, playback["title"]?.toString())
                .putString(MediaMetadataCompat.METADATA_KEY_DISPLAY_SUBTITLE, playback["artist"]?.toString())
                .putLong(
                    MediaMetadataCompat.METADATA_KEY_DURATION,
                    (playback["durationMs"] as? Number)?.toLong() ?: -1L,
                )

        val artwork = decodeArtwork(playback)
        if (artwork != null) {
            builder
                .putBitmap(MediaMetadataCompat.METADATA_KEY_ALBUM_ART, artwork)
                .putBitmap(MediaMetadataCompat.METADATA_KEY_DISPLAY_ICON, artwork)
        }

        return builder.build()
    }

    private fun decodeArtwork(playback: Map<String, Any?>): Bitmap? {
        val artwork = playback["artwork"] as? Map<*, *> ?: return null
        val dataBase64 = artwork["dataBase64"]?.toString()?.takeIf { it.isNotBlank() } ?: return null
        return try {
            val bytes = Base64.decode(dataBase64, Base64.DEFAULT)
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
        } catch (_: IllegalArgumentException) {
            null
        }
    }

    private fun buildPlaybackState(playback: Map<String, Any?>): PlaybackStateCompat {
        var actions = 0L
        if (playback["canPlay"] == true) {
            actions = actions or PlaybackStateCompat.ACTION_PLAY
        }
        if (playback["canPause"] == true) {
            actions = actions or PlaybackStateCompat.ACTION_PAUSE
        }
        if (playback["canSkipNext"] == true) {
            actions = actions or PlaybackStateCompat.ACTION_SKIP_TO_NEXT
        }
        if (playback["canSkipPrevious"] == true) {
            actions = actions or PlaybackStateCompat.ACTION_SKIP_TO_PREVIOUS
        }
        if (playback["canSeek"] == true) {
            actions = actions or PlaybackStateCompat.ACTION_SEEK_TO
        }

        val state =
            when (playback["playbackState"]?.toString()) {
                "playing" -> PlaybackStateCompat.STATE_PLAYING
                "paused" -> PlaybackStateCompat.STATE_PAUSED
                "buffering" -> PlaybackStateCompat.STATE_BUFFERING
                else -> PlaybackStateCompat.STATE_STOPPED
            }

        return PlaybackStateCompat.Builder()
            .setActions(actions)
            .setState(
                state,
                (playback["positionMs"] as? Number)?.toLong() ?: 0L,
                if (state == PlaybackStateCompat.STATE_PLAYING) 1f else 0f,
            )
            .build()
    }
}
