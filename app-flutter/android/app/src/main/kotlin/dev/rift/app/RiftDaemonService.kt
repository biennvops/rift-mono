package dev.rift.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.FlutterInjector
import io.flutter.plugins.GeneratedPluginRegistrant
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class RiftDaemonService : Service() {
    companion object {
        private const val channelId = "rift.daemon"
        private const val channelName = "Rift background sync"
        private const val notificationId = 4108
        private const val mirroredNotificationId = 4110
        private const val actionStart = "dev.rift.app.action.START_DAEMON_SERVICE"
        private const val actionStop = "dev.rift.app.action.STOP_DAEMON_SERVICE"
        internal const val preferencesName = "rift_background_sync"
        internal const val backgroundEnabledKey = "enabled"

        fun start(context: Context) {
            context.getSharedPreferences(preferencesName, Context.MODE_PRIVATE)
                .edit()
                .putBoolean(backgroundEnabledKey, true)
                .apply()
            val intent = Intent(context, RiftDaemonService::class.java).apply {
                action = actionStart
            }
            ContextCompat.startForegroundService(context, intent)
        }

        fun stop(context: Context) {
            context.getSharedPreferences(preferencesName, Context.MODE_PRIVATE)
                .edit()
                .putBoolean(backgroundEnabledKey, false)
                .apply()
            val intent = Intent(context, RiftDaemonService::class.java).apply {
                action = actionStop
            }
            context.startService(intent)
        }
    }

    private var engine: FlutterEngine? = null
    private var tlsBridge: AndroidTlsBridge? = null
    private var mediaObserver: AndroidMediaSessionObserver? = null
    private var remoteMediaPlaybackManager: RemoteMediaPlaybackManager? = null

    override fun onCreate() {
        super.onCreate()
        createChannel()
        createActivityNotificationChannel()
        createMediaPlaybackNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            actionStop -> {
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
                return START_NOT_STICKY
            }
            else -> {
                ServiceCompat.startForeground(
                    this,
                    notificationId,
                    buildNotification(),
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                        ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
                    } else {
                        0
                    },
                )
                startBackgroundRuntime()
                return START_STICKY
            }
        }
    }

    override fun onDestroy() {
        mediaObserver?.stopObservation()
        mediaObserver = null
        remoteMediaPlaybackManager?.stop()
        remoteMediaPlaybackManager = null
        tlsBridge?.dispose()
        tlsBridge = null
        RiftBackgroundHost.detachService()
        engine?.destroy()
        engine = null
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun startBackgroundRuntime() {
        if (engine != null) {
            return
        }

        val flutterEngine = FlutterEngine(this)
        GeneratedPluginRegistrant.registerWith(flutterEngine)
        engine = flutterEngine

        val identityChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "rift/android/identity",
        )
        identityChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "loadOrCreate" -> {
                    try {
                        val legacyPath =
                            (call.arguments as? Map<*, *>)?.get("legacyPath") as? String
                        result.success(AndroidIdentityKeystore.loadOrCreate(this, legacyPath))
                    } catch (error: Exception) {
                        result.error("identity_keystore_error", error.message, null)
                    }
                }
                "getDeviceInfo" -> result.success(AndroidDeviceInfo.asMap(this))
                else -> result.notImplemented()
            }
        }

        val tls = AndroidTlsBridge()
        tlsBridge = tls
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "rift/android/tls",
        ).setMethodCallHandler { call, result -> tls.handle(call, result) }

        RiftBackgroundHost.attachService(this, flutterEngine, ::handleNativeCommand)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "rift/android/shell",
        ).setMethodCallHandler { call, result -> handleNativeCommand(call.method, call.arguments, result) }

        remoteMediaPlaybackManager = RemoteMediaPlaybackManager(
            this,
            launchIntentFactory = {
                Intent(this, MainActivity::class.java).apply {
                    flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
                }
            },
            actionCallback = { action ->
                val event = linkedMapOf<String, Any?>("eventType" to "mediaPlaybackAction")
                event.putAll(action)
                RiftBackgroundHost.sendNativeEvent(this, event)
            },
        ).also { it.start() }

        mediaObserver = AndroidMediaSessionObserver(this) { event ->
            RiftBackgroundHost.sendNativeEvent(this, event)
        }.also { it.startObservation() }

        val loader = FlutterInjector.instance().flutterLoader()
        if (!loader.initialized()) {
            loader.startInitialization(this)
        }
        loader.ensureInitializationComplete(this, null)
        flutterEngine.dartExecutor.executeDartEntrypoint(
            DartExecutor.DartEntrypoint(
                loader.findAppBundlePath(),
                "androidBackgroundMain",
            ),
        )
    }

    private fun handleNativeCommand(
        method: String,
        arguments: Any?,
        result: MethodChannel.Result,
    ) {
        when (method) {
            "getDeviceStatus" -> result.success(AndroidDeviceStatus.asMap(this))
            "showNotification" -> {
                result.success(showActivityNotification(arguments))
            }
            "clearNotification" -> {
                val notificationKey =
                    (arguments as? Map<*, *>)?.get("notificationKey") as? String
                if (notificationKey.isNullOrBlank()) {
                    result.error("invalid_args", "notificationKey is required", null)
                } else {
                    result.success(clearActivityNotification(notificationKey))
                }
            }
            "showMediaPlayback" -> {
                val playback = (arguments as? Map<*, *>)?.get("playback") as? Map<*, *>
                if (playback == null) {
                    result.error("invalid_args", "playback is required", null)
                } else {
                    result.success(
                        remoteMediaPlaybackManager?.show(
                            playback.entries.associate { it.key.toString() to it.value },
                        ) ?: false,
                    )
                }
            }
            "clearMediaPlayback" -> result.success(remoteMediaPlaybackManager?.clear() ?: false)
            "performMediaPlaybackAction" -> {
                val args = arguments as? Map<*, *>
                val playbackId = args?.get("playbackId") as? String
                val action = args?.get("action") as? String
                if (playbackId == null || action == null) {
                    result.error("invalid_args", "playbackId and action are required", null)
                } else {
                    val positionMs = (args["positionMs"] as? Number)?.toLong()
                    result.success(
                        mediaObserver?.performAction(playbackId, action, positionMs)
                            ?: mapOf(
                                "success" to false,
                                "failureReason" to "CapabilityUnavailable",
                                "message" to "Android media observer is unavailable.",
                            ),
                    )
                }
            }
            "performNotificationAction" -> {
                val args = arguments as? Map<*, *>
                val notificationId = args?.get("notificationId") as? String
                val action = args?.get("action") as? String
                if (notificationId == null || action == null) {
                    result.error("invalid_args", "notificationId and action are required", null)
                } else {
                    result.success(
                        RiftNotificationListenerService.performAction(notificationId, action),
                    )
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun createActivityNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.createNotificationChannel(
            NotificationChannel(
                "rift.events",
                "Rift activity",
                NotificationManager.IMPORTANCE_DEFAULT,
            ).apply { description = "Rift pairing, clipboard, and file activity" },
        )
    }

    private fun createMediaPlaybackNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.createNotificationChannel(
            NotificationChannel(
                RemoteMediaPlaybackManager.notificationChannelId,
                RemoteMediaPlaybackManager.notificationChannelName,
                NotificationManager.IMPORTANCE_LOW,
            ),
        )
    }

    private fun showActivityNotification(arguments: Any?): Boolean {
        val args = arguments as? Map<*, *> ?: return false
        val title = args["title"] as? String ?: return false
        val body = args["body"] as? String ?: return false
        val route = args["route"] as? String ?: return false
        val payload = args["payload"] as? Map<*, *>
        val notificationKey = args["notificationKey"] as? String
        val launchIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra("rift.notification.route", route)
            payload?.forEach { (key, value) ->
                val name = key as? String ?: return@forEach
                when (value) {
                    is String -> putExtra("rift.notification.payload.$name", value)
                    is Boolean -> putExtra("rift.notification.payload.$name", value)
                    is Int -> putExtra("rift.notification.payload.$name", value)
                    is Long -> putExtra("rift.notification.payload.$name", value)
                }
            }
        }
        val pendingIntent = PendingIntent.getActivity(
            this,
            (route + title + body).hashCode(),
            launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val notificationId =
            (payload?.get("notificationId")?.toString() ?: "$route:$title:$body").hashCode()
        val notification = NotificationCompat.Builder(this, "rift.events")
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(title)
            .setContentText(body)
            .setContentIntent(pendingIntent)
            .setAutoCancel(true)
            .setOnlyAlertOnce(!notificationKey.isNullOrBlank())
            .build()
        return try {
            val manager = NotificationManagerCompat.from(this)
            if (notificationKey.isNullOrBlank()) {
                manager.notify(notificationId, notification)
            } else {
                manager.notify(notificationKey, mirroredNotificationId, notification)
            }
            true
        } catch (_: SecurityException) {
            false
        }
    }

    private fun clearActivityNotification(notificationKey: String): Boolean {
        NotificationManagerCompat.from(this).cancel(notificationKey, mirroredNotificationId)
        return true
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val channel = NotificationChannel(
            channelId,
            channelName,
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "Keeps Rift network sync available while the app is backgrounded"
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }

    private fun buildNotification(): Notification {
        val launchIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        return NotificationCompat.Builder(this, channelId)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("Rift background sync active")
            .setContentText("Keeping trusted peer sync available while the app is in the background")
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setContentIntent(pendingIntent)
            .build()
    }
}
