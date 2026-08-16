package dev.rift.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
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
        private const val shutdownFallbackDelayMs = 5_000L
        private const val logTag = "RiftDaemonService"
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
    private val mainHandler = Handler(Looper.getMainLooper())
    private var runtimeGeneration = 1
    private var runtimeShutdownStarted = false
    private var stopServiceAfterShutdown = false
    private var restartAfterShutdown = false
    private var runtimeFinalizer = RuntimeShutdownFinalizer(::finalizeRuntime)
    private var shutdownFallback: Runnable? = null

    override fun onCreate() {
        super.onCreate()
        createChannel()
        createActivityNotificationChannel()
        createMediaPlaybackNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            actionStop -> {
                requestRuntimeShutdown(stopServiceAfterward = true)
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
                if (runtimeShutdownStarted) {
                    restartAfterShutdown = true
                    Log.i(
                        logTag,
                        "Restart queued until runtime shutdown completes " +
                            "generation=$runtimeGeneration",
                    )
                    return START_STICKY
                }
                startBackgroundRuntime()
                return START_STICKY
            }
        }
    }

    override fun onDestroy() {
        val restartAfterDestroy =
            restartAfterShutdown && runtimeFinalizer.isFinalized()
        requestRuntimeShutdown(stopServiceAfterward = false)
        super.onDestroy()
        if (restartAfterDestroy) {
            restartAfterShutdown = false
            Log.i(logTag, "Restarting daemon after service destruction")
            mainHandler.post {
                start(applicationContext)
            }
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun requestRuntimeShutdown(stopServiceAfterward: Boolean) {
        stopServiceAfterShutdown = stopServiceAfterShutdown || stopServiceAfterward
        stopNativeEventProducers()
        if (runtimeFinalizer.isFinalized() || runtimeShutdownStarted) {
            return
        }

        runtimeShutdownStarted = true
        val shutdownGeneration = runtimeGeneration
        Log.i(
            logTag,
            "Android service shutdown requested generation=$shutdownGeneration",
        )
        if (engine == null) {
            completeRuntimeShutdown(shutdownGeneration)
            return
        }

        val fallback = Runnable {
            Log.w(
                logTag,
                "Shutdown fallback triggered generation=$shutdownGeneration",
            )
            completeRuntimeShutdown(shutdownGeneration)
        }
        shutdownFallback = fallback
        mainHandler.postDelayed(fallback, shutdownFallbackDelayMs)
        try {
            RiftBackgroundHost.requestRuntimeShutdown(
                object : MethodChannel.Result {
                    override fun success(result: Any?) {
                        Log.i(
                            logTag,
                            "Dart runtime shutdown acknowledged " +
                                "generation=$shutdownGeneration",
                        )
                        completeRuntimeShutdown(shutdownGeneration)
                    }

                    override fun error(
                        errorCode: String,
                        errorMessage: String?,
                        errorDetails: Any?,
                    ) {
                        Log.w(
                            logTag,
                            "Dart runtime shutdown failed " +
                                "generation=$shutdownGeneration: " +
                                "$errorCode $errorMessage",
                        )
                        completeRuntimeShutdown(shutdownGeneration)
                    }

                    override fun notImplemented() {
                        Log.w(
                            logTag,
                            "Dart runtime shutdown is not implemented " +
                                "generation=$shutdownGeneration",
                        )
                        completeRuntimeShutdown(shutdownGeneration)
                    }
                },
            )
        } catch (error: Exception) {
            Log.w(logTag, "Unable to request Dart runtime shutdown", error)
            completeRuntimeShutdown(shutdownGeneration)
        }
    }

    private fun stopNativeEventProducers() {
        RiftBackgroundHost.beginServiceShutdown()
        mediaObserver?.stopObservation()
        mediaObserver = null
        remoteMediaPlaybackManager?.stop()
        remoteMediaPlaybackManager = null
    }

    private fun completeRuntimeShutdown(shutdownGeneration: Int) {
        if (shutdownGeneration != runtimeGeneration || !runtimeShutdownStarted) {
            return
        }
        shutdownFallback?.let(mainHandler::removeCallbacks)
        shutdownFallback = null
        if (!runtimeFinalizer.finalizeOnce()) {
            return
        }
        if (restartAfterShutdown) {
            restartAfterShutdown = false
            stopServiceAfterShutdown = false
            runtimeShutdownStarted = false
            runtimeGeneration += 1
            runtimeFinalizer = RuntimeShutdownFinalizer(::finalizeRuntime)
            Log.i(
                logTag,
                "Starting queued service runtime generation=$runtimeGeneration",
            )
            startBackgroundRuntime()
            return
        }
        if (stopServiceAfterShutdown) {
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
        }
    }

    private fun finalizeRuntime() {
        val nativeTlsBridge = tlsBridge
        tlsBridge = null
        val flutterEngine = engine
        engine = null
        try {
            nativeTlsBridge?.dispose()
        } catch (error: Exception) {
            Log.w(logTag, "Failed to dispose native TLS bridge", error)
        }
        try {
            RiftBackgroundHost.detachService()
        } catch (error: Exception) {
            Log.w(logTag, "Failed to detach background host", error)
        }
        try {
            flutterEngine?.destroy()
        } catch (error: Exception) {
            Log.w(logTag, "Failed to destroy Flutter engine", error)
        }
        Log.i(logTag, "Native service runtime finalized")
    }

    private fun startBackgroundRuntime() {
        if (engine != null || runtimeShutdownStarted) {
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
        val icon = decodeNotificationIcon(args["iconBytes"])
        val launchIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            if (!notificationKey.isNullOrBlank()) {
                data = Uri.parse("rift://notification/$notificationKey")
            }
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
            notificationKey?.hashCode() ?: (route + title + body).hashCode(),
            launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val notificationId =
            (payload?.get("notificationId")?.toString() ?: "$route:$title:$body").hashCode()
        val builder = NotificationCompat.Builder(this, "rift.events")
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(title)
            .setContentText(body)
            .setContentIntent(pendingIntent)
            .setAutoCancel(true)
            .setOnlyAlertOnce(!notificationKey.isNullOrBlank())
        if (icon != null) {
            builder.setLargeIcon(icon)
        }
        val notification = builder.build()
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

    private fun decodeNotificationIcon(value: Any?): Bitmap? {
        val bytes = value as? ByteArray ?: return null
        if (bytes.isEmpty() || bytes.size > NotificationIconLimits.maxRawBytes) {
            return null
        }

        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) {
            return null
        }

        var sampleSize = 1
        while (bounds.outWidth / sampleSize > NotificationIconLimits.renderSize ||
            bounds.outHeight / sampleSize > NotificationIconLimits.renderSize) {
            sampleSize *= 2
        }
        val options = BitmapFactory.Options().apply {
            inSampleSize = sampleSize
            inPreferredConfig = Bitmap.Config.ARGB_8888
        }
        return BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options)
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
