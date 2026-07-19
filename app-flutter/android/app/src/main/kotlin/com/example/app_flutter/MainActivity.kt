package com.example.app_flutter

import android.Manifest
import android.content.ActivityNotFoundException
import android.content.BroadcastReceiver
import android.content.ClipboardManager
import android.content.ComponentName
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.database.Cursor
import android.net.Uri
import android.os.Bundle
import android.os.Build
import android.os.Environment
import android.content.pm.PackageManager
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.provider.Settings
import android.webkit.MimeTypeMap
import android.util.Log
import android.widget.Toast
import androidx.core.app.ActivityCompat
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.UUID

class MainActivity: FlutterActivity() {
    companion object {
        private const val notificationChannelId = "rift.events"
        private const val notificationChannelName = "Rift activity"
        private const val syncTestExtraKey = "com.example.app_flutter.SYNC_TEST_NOTIFICATION"
        private const val notificationIntentRouteKey = "rift.notification.route"
        private const val notificationIntentDestinationPathKey = "rift.notification.destinationPath"
        private const val notificationIntentPayloadPrefix = "rift.notification.payload."
        private const val shareSendRoute = "history.send"
        private const val shareClipboardRoute = "history.clipboard"
        private const val notificationPermissionRequestCode = 4107
        @JvmStatic
        var isClipboardRelayReady: Boolean = false
    }

    private val clipboardChannelName = "com.biennvops.rift/clipboard"
    private val shellChannelName = "rift/android/shell"
    private val tag = "RiftMainActivity"
    private var clipboardChannel: MethodChannel? = null
    private var shellChannel: MethodChannel? = null
    private lateinit var remoteMediaPlaybackManager: RemoteMediaPlaybackManager
    private var pendingLaunchAction: Map<String, Any?>? = null
    private var pendingNotificationPermissionResult: MethodChannel.Result? = null
    private var clipboardReceiverRegistered: Boolean = false
    private var notificationSyncReceiverRegistered: Boolean = false

    private val clipboardReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            val text = intent?.getStringExtra("text")
            val contentType = intent?.getStringExtra("contentType")
            val contentBase64 = intent?.getStringExtra("contentBase64")
            when {
                text != null -> {
                    Log.i(tag, "Received clipboard broadcast length=${text.length}")
                    clipboardChannel?.invokeMethod("onClipboardChanged", mapOf("text" to text))
                }
                contentType != null && contentBase64 != null -> {
                    Log.i(
                        tag,
                        "Received clipboard broadcast contentType=$contentType base64Length=${contentBase64.length}",
                    )
                    clipboardChannel?.invokeMethod(
                        "onClipboardChanged",
                        mapOf(
                            "contentType" to contentType,
                            "contentBase64" to contentBase64,
                        ),
                    )
                }
                else -> {
                    Log.i(tag, "Received clipboard broadcast with no supported payload")
                }
            }
        }
    }

    private val notificationSyncReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            val payload = extractNotificationSyncPayload(intent) ?: return
            NotificationSyncRelay.acknowledgeDeliveredEvent(this@MainActivity, payload)
            shellChannel?.invokeMethod("notificationSyncEvent", payload)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        Log.i(tag, "configureFlutterEngine")
        createNotificationChannel()
        createMediaPlaybackNotificationChannel()
        isClipboardRelayReady = true
        remoteMediaPlaybackManager =
            RemoteMediaPlaybackManager(
                this,
                launchIntentFactory = {
                    Intent(this, MainActivity::class.java).apply {
                        flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
                    }
                },
                actionCallback = { action ->
                    shellChannel?.invokeMethod("mediaPlaybackAction", action)
                },
            )
        remoteMediaPlaybackManager.start()
        clipboardChannel =
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, clipboardChannelName)

        clipboardChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "startService" -> {
                    Log.i(tag, "startService requested from Flutter")
                    RiftDaemonService.start(this)
                    result.success(true)
                }
                "stopService" -> {
                    Log.i(tag, "stopService requested from Flutter")
                    RiftDaemonService.stop(this)
                    result.success(true)
                }
                "setClipboardContent" -> {
                    val args = call.arguments as? Map<*, *>
                    val contentType = args?.get("contentType") as? String
                    val contentBase64 = args?.get("contentBase64") as? String
                    if (contentType == null || contentBase64 == null) {
                        result.error("invalid_args", "contentType and contentBase64 are required", null)
                    } else {
                        val clipboard =
                            getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                        val applied = AndroidClipboardCodec.applyClipboardPayload(
                            this,
                            clipboard,
                            contentType,
                            contentBase64,
                        )
                        result.success(applied)
                    }
                }
                "getCurrentClipboardPayload" -> {
                    val clipboard =
                        getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                    result.success(AndroidClipboardCodec.encodePrimaryClip(this, clipboard))
                }
                else -> result.notImplemented()
            }
        }

        shellChannel =
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, shellChannelName)
        shellChannel?.setMethodCallHandler { call, result ->
                when (call.method) {
                    "consumeLaunchAction" -> {
                        val action = pendingLaunchAction
                        pendingLaunchAction = null
                        result.success(action)
                    }
                    "getPublicDownloadsDirectory" -> {
                        result.success(getPublicDownloadsDirectory())
                    }
                    "prepareIncomingDownload" -> {
                        val args = call.arguments as? Map<*, *>
                        val fileName = args?.get("fileName") as? String
                        if (fileName.isNullOrBlank()) {
                            result.error("invalid_args", "fileName is required", null)
                        } else {
                            try {
                                result.success(prepareIncomingDownload(fileName))
                            } catch (e: Exception) {
                                Log.e(tag, "Failed to prepare incoming download", e)
                                result.error("download_prepare_failed", e.message, null)
                            }
                        }
                    }
                    "publishIncomingDownload" -> {
                        val args = call.arguments as? Map<*, *>
                        val stagingPath = args?.get("stagingPath") as? String
                        val fileName = args?.get("fileName") as? String
                        val mediaType = args?.get("mediaType") as? String
                        if (stagingPath.isNullOrBlank() || fileName.isNullOrBlank()) {
                            result.error(
                                "invalid_args",
                                "stagingPath and fileName are required",
                                null,
                            )
                        } else {
                            try {
                                result.success(
                                    publishIncomingDownload(
                                        stagingPath,
                                        fileName,
                                        mediaType ?: "application/octet-stream",
                                    ),
                                )
                            } catch (e: Exception) {
                                Log.e(tag, "Failed to publish incoming download", e)
                                result.error("download_publish_failed", e.message, null)
                            }
                        }
                    }
                    "getNotificationPermissionStatus" -> {
                        result.success(getNotificationPermissionStatus())
                    }
                    "requestNotificationPermission" -> {
                        requestNotificationPermission(result)
                    }
                    "performLocalNotificationAction" -> {
                        val args = call.arguments as? Map<*, *>
                        val notificationId = args?.get("notificationId") as? String
                        val action = args?.get("action") as? String
                        if (notificationId.isNullOrBlank() || action.isNullOrBlank()) {
                            result.error(
                                "invalid_args",
                                "notificationId and action are required",
                                null,
                            )
                        } else {
                            result.success(
                                RiftNotificationListenerService.performAction(
                                    notificationId,
                                    action,
                                ),
                            )
                        }
                    }
                    "showNotification" -> {
                        val args = call.arguments as? Map<*, *>
                        val title = args?.get("title") as? String
                        val body = args?.get("body") as? String
                        val route = args?.get("route") as? String
                        val destinationPath = args?.get("destinationPath") as? String
                        val payload = args?.get("payload") as? Map<*, *>
                        if (title.isNullOrBlank() || body.isNullOrBlank() || route.isNullOrBlank()) {
                            result.error("invalid_args", "title, body, and route are required", null)
                        } else {
                            result.success(
                                showNotification(
                                    title = title,
                                    body = body,
                                    route = route,
                                    destinationPath = destinationPath,
                                    payload = payload,
                                )
                            )
                        }
                    }
                    "showToast" -> {
                        val args = call.arguments as? Map<*, *>
                        val message = args?.get("message") as? String
                        if (message.isNullOrBlank()) {
                            result.error("invalid_args", "message is required", null)
                        } else {
                            Toast.makeText(this, message, Toast.LENGTH_SHORT).show()
                            result.success(true)
                        }
                    }
                    "openNotificationSettings" -> {
                        result.success(openNotificationSettings())
                    }
                    "getNotificationListenerAccessStatus" -> {
                        result.success(getNotificationListenerAccessStatus())
                    }
                    "openNotificationListenerSettings" -> {
                        result.success(openNotificationListenerSettings())
                    }
                    "showTestNotification" -> {
                        result.success(showTestNotification())
                    }
                    "showMediaPlayback" -> {
                        val args = call.arguments as? Map<*, *>
                        val playback = args?.get("playback") as? Map<*, *>
                        if (playback == null) {
                            result.error("invalid_args", "playback is required", null)
                        } else {
                            result.success(
                                remoteMediaPlaybackManager.show(
                                    playback.entries.associate { (key, value) ->
                                        key.toString() to value
                                    },
                                ),
                            )
                        }
                    }
                    "clearMediaPlayback" -> {
                        result.success(remoteMediaPlaybackManager.clear())
                    }
                    "openFile" -> {
                        val args = call.arguments as? Map<*, *>
                        val path = args?.get("path") as? String
                        if (path.isNullOrBlank()) {
                            result.error("invalid_args", "path is required", null)
                        } else {
                            result.success(openFile(path))
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        handleLaunchIntent(intent)

        val filter = IntentFilter("com.example.app_flutter.CLIPBOARD_CHANGED")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(clipboardReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(clipboardReceiver, filter)
        }
        clipboardReceiverRegistered = true
        Log.i(tag, "Clipboard broadcast receiver registered")

        val notificationSyncFilter = IntentFilter(NotificationSyncRelay.broadcastAction)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(
                notificationSyncReceiver,
                notificationSyncFilter,
                Context.RECEIVER_NOT_EXPORTED,
            )
        } else {
            registerReceiver(notificationSyncReceiver, notificationSyncFilter)
        }
        notificationSyncReceiverRegistered = true
        deliverPendingNotificationSyncEvents()
    }

    override fun onStart() {
        super.onStart()
        Log.i(tag, "onStart")
    }

    override fun onResume() {
        super.onResume()
        Log.i(tag, "onResume")
        deliverPendingLaunchActionIfPossible()
        deliverPendingNotificationSyncEvents()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleLaunchIntent(intent)
    }

    override fun onPause() {
        Log.i(tag, "onPause")
        super.onPause()
    }

    override fun onStop() {
        Log.i(tag, "onStop")
        super.onStop()
    }

    override fun onDestroy() {
        Log.i(tag, "onDestroy")
        isClipboardRelayReady = false
        if (clipboardReceiverRegistered) {
            unregisterReceiver(clipboardReceiver)
            clipboardReceiverRegistered = false
        }
        if (notificationSyncReceiverRegistered) {
            unregisterReceiver(notificationSyncReceiver)
            notificationSyncReceiverRegistered = false
        }
        remoteMediaPlaybackManager.stop()
        super.onDestroy()
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != notificationPermissionRequestCode) {
            return
        }

        val granted =
            grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
        pendingNotificationPermissionResult?.success(granted)
        pendingNotificationPermissionResult = null
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return
        }
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val channel = NotificationChannel(
            notificationChannelId,
            notificationChannelName,
            NotificationManager.IMPORTANCE_DEFAULT,
        ).apply {
            description = "Rift pairing, clipboard, and file activity"
        }
        manager.createNotificationChannel(channel)
    }

    private fun createMediaPlaybackNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return
        }
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val channel =
            NotificationChannel(
                RemoteMediaPlaybackManager.notificationChannelId,
                RemoteMediaPlaybackManager.notificationChannelName,
                NotificationManager.IMPORTANCE_LOW,
            )
        manager.createNotificationChannel(channel)
    }

    private fun getNotificationPermissionStatus(): String {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val granted =
                ContextCompat.checkSelfPermission(
                    this,
                    Manifest.permission.POST_NOTIFICATIONS,
                ) == PackageManager.PERMISSION_GRANTED
            return if (granted) "authorized" else "denied"
        }

        return if (NotificationManagerCompat.from(this).areNotificationsEnabled()) {
            "authorized"
        } else {
            "denied"
        }
    }

    private fun requestNotificationPermission(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            result.success(NotificationManagerCompat.from(this).areNotificationsEnabled())
            return
        }

        if (
            ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.POST_NOTIFICATIONS,
            ) == PackageManager.PERMISSION_GRANTED
        ) {
            result.success(true)
            return
        }

        pendingNotificationPermissionResult = result
        ActivityCompat.requestPermissions(
            this,
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            notificationPermissionRequestCode,
        )
    }

    private fun openNotificationSettings(): Boolean {
        val intent =
            Intent().apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK
                action =
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        Settings.ACTION_APP_NOTIFICATION_SETTINGS
                    } else {
                        Settings.ACTION_APPLICATION_DETAILS_SETTINGS
                    }

                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                } else {
                    data = Uri.fromParts("package", packageName, null)
                }
            }

        return try {
            startActivity(intent)
            true
        } catch (e: ActivityNotFoundException) {
            Log.w(tag, "Unable to open notification settings", e)
            false
        }
    }

    private fun getNotificationListenerAccessStatus(): String {
        val enabledPackages = NotificationManagerCompat.getEnabledListenerPackages(this)
        return if (enabledPackages.contains(packageName)) "authorized" else "denied"
    }

    private fun openNotificationListenerSettings(): Boolean {
        val intent =
            Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK
                putExtra(":settings:fragment_args_key", ComponentName(this@MainActivity, RiftNotificationListenerService::class.java).flattenToString())
            }

        return try {
            startActivity(intent)
            true
        } catch (e: ActivityNotFoundException) {
            Log.w(tag, "Unable to open notification listener settings", e)
            false
        }
    }

    private fun showTestNotification(): Boolean {
        if (getNotificationPermissionStatus() != "authorized") {
            return false
        }

        return showNotification(
            title = "Rift test notification",
            body = "If you see this notification, sync is working.",
            route = "history.notifications",
            destinationPath = null,
            payload = mapOf("testNotification" to true),
            isSyncTestNotification = true,
        )
    }

    private fun showNotification(
        title: String,
        body: String,
        route: String,
        destinationPath: String?,
        payload: Map<*, *>?,
        isSyncTestNotification: Boolean = false,
    ): Boolean {
        val intent =
            Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
                putExtra(notificationIntentRouteKey, route)
                if (!destinationPath.isNullOrBlank()) {
                    putExtra(notificationIntentDestinationPathKey, destinationPath)
                }
                payload?.forEach { (key, value) ->
                    val stringKey = key as? String ?: return@forEach
                    when (value) {
                        is String -> putExtra("$notificationIntentPayloadPrefix$stringKey", value)
                        is Int -> putExtra("$notificationIntentPayloadPrefix$stringKey", value)
                        is Long -> putExtra("$notificationIntentPayloadPrefix$stringKey", value)
                        is Boolean -> putExtra("$notificationIntentPayloadPrefix$stringKey", value)
                        is Double -> putExtra("$notificationIntentPayloadPrefix$stringKey", value)
                    }
                }
            }
        val pendingIntent =
            PendingIntent.getActivity(
                this,
                route.hashCode(),
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )

        val notification =
            NotificationCompat.Builder(this, notificationChannelId)
                .setSmallIcon(R.mipmap.ic_launcher)
                .setContentTitle(title)
                .setContentText(body)
                .setStyle(NotificationCompat.BigTextStyle().bigText(body))
                .setAutoCancel(true)
                .setPriority(NotificationCompat.PRIORITY_DEFAULT)
                .setContentIntent(pendingIntent)
                .addExtras(
                    Bundle().apply {
                        putBoolean(syncTestExtraKey, isSyncTestNotification)
                    },
                )
                .build()

        return try {
            NotificationManagerCompat.from(this).notify(
                (System.currentTimeMillis() % Int.MAX_VALUE).toInt(),
                notification,
            )
            true
        } catch (e: SecurityException) {
            Log.w(tag, "Notification permission denied", e)
            false
        }
    }

    private fun handleNotificationIntent(intent: Intent?) {
        val action = extractNotificationAction(intent) ?: return
        val destinationPath = action["destinationPath"] as? String
        val openDestination = action["openDestination"] as? Boolean ?: false
        if (openDestination && !destinationPath.isNullOrBlank() && openFile(destinationPath)) {
            return
        }
        pendingLaunchAction = action
        deliverPendingLaunchActionIfPossible()
    }

    private fun handleLaunchIntent(intent: Intent?) {
        if (handleShareIntent(intent)) {
            return
        }
        handleNotificationIntent(intent)
    }

    private fun handleShareIntent(intent: Intent?): Boolean {
        val action = intent?.action ?: return false
        val type = intent.type
        val items =
            when (action) {
                Intent.ACTION_SEND -> buildSharedItemsFromSendIntent(intent, type)
                Intent.ACTION_SEND_MULTIPLE -> buildSharedItemsFromSendMultipleIntent(intent, type)
                else -> null
            } ?: return false

        if (items.isEmpty()) {
            return false
        }

        pendingLaunchAction = if (items.size == 1 && items.first().containsKey("sharedText")) {
            mapOf(
                "route" to shareClipboardRoute,
                "sharedText" to items.first().getValue("sharedText"),
            )
        } else {
            mapOf(
                "route" to shareSendRoute,
                "items" to items,
            )
        }
        deliverPendingLaunchActionIfPossible()
        return true
    }

    private fun buildSharedItemsFromSendIntent(
        intent: Intent,
        mimeType: String?,
    ): List<Map<String, String>>? {
        val streamUri =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
            } else {
                @Suppress("DEPRECATION")
                intent.getParcelableExtra(Intent.EXTRA_STREAM) as? Uri
            }
        if (streamUri != null) {
            return listOfNotNull(importSharedUri(streamUri, mimeType))
        }

        val text = intent.getStringExtra(Intent.EXTRA_TEXT)
        if (!text.isNullOrBlank()) {
            return listOf(mapOf("sharedText" to text))
        }

        return null
    }

    private fun buildSharedItemsFromSendMultipleIntent(
        intent: Intent,
        mimeType: String?,
    ): List<Map<String, String>>? {
        val uris =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
            } else {
                @Suppress("DEPRECATION")
                intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)
            } ?: return null

        return uris.mapNotNull { uri -> importSharedUri(uri, mimeType) }
    }

    private fun importSharedUri(uri: Uri, fallbackMimeType: String?): Map<String, String>? {
        return try {
            val shareDir = File(cacheDir, "shared-imports").apply {
                mkdirs()
            }
            val metadata = querySharedMetadata(uri)
            val resolvedMimeType =
                contentResolver.getType(uri)
                    ?: fallbackMimeType
                    ?: metadata.second?.let { fileName ->
                        val ext = MimeTypeMap.getFileExtensionFromUrl(fileName)
                        if (ext.isNullOrBlank()) {
                            null
                        } else {
                            MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext.lowercase())
                        }
                    }
                    ?: "application/octet-stream"
            val displayName =
                metadata.first?.takeIf { it.isNotBlank() }
                    ?: "shared-${System.currentTimeMillis()}"
            val safeName = displayName.replace(Regex("[<>:\"/\\\\|?*]"), "_")
            val targetFile = File(shareDir, "${System.currentTimeMillis()}_$safeName")
            contentResolver.openInputStream(uri)?.use { input ->
                targetFile.outputStream().use { output ->
                    input.copyTo(output)
                }
            } ?: return null

            mapOf(
                "localPath" to targetFile.absolutePath,
                "fileName" to displayName,
                "mediaType" to resolvedMimeType,
            )
        } catch (e: Exception) {
            Log.e(tag, "Failed to import shared Uri: $uri", e)
            null
        }
    }
    private fun querySharedMetadata(uri: Uri): Pair<String?, String?> {
        var displayName: String? = null
        var extensionSource: String? = null
        val cursor: Cursor? =
            contentResolver.query(uri, null, null, null, null)
        cursor?.use {
            val nameIndex = it.getColumnIndex(OpenableColumns.DISPLAY_NAME)
            if (nameIndex >= 0 && it.moveToFirst()) {
                displayName = it.getString(nameIndex)
                extensionSource = displayName
            }
        }
        if (displayName == null) {
            val pathSegment = uri.lastPathSegment
            if (!pathSegment.isNullOrBlank()) {
                displayName = pathSegment.substringAfterLast('/')
                extensionSource = displayName
            }
        }
        return Pair(displayName, extensionSource)
    }

    private fun extractNotificationAction(intent: Intent?): Map<String, Any?>? {
        val route = intent?.getStringExtra(notificationIntentRouteKey) ?: return null
        val action = mutableMapOf<String, Any?>("route" to route)
        intent.getStringExtra(notificationIntentDestinationPathKey)?.let {
            action["destinationPath"] = it
        }
        val extras = intent.extras ?: Bundle.EMPTY
        for (key in extras.keySet()) {
            if (!key.startsWith(notificationIntentPayloadPrefix)) {
                continue
            }
            val payloadKey = key.removePrefix(notificationIntentPayloadPrefix)
            action[payloadKey] = extras.get(key)
        }
        return action
    }

    private fun deliverPendingLaunchActionIfPossible() {
        val action = pendingLaunchAction ?: return
        shellChannel?.invokeMethod("notificationActivated", action)
        pendingLaunchAction = null
    }

    private fun deliverPendingNotificationSyncEvents() {
        val channel = shellChannel ?: return
        NotificationSyncRelay.drainPendingEvents(this).forEach { event ->
            channel.invokeMethod("notificationSyncEvent", event)
        }
    }

    private fun extractNotificationSyncPayload(intent: Intent?): Map<String, Any?>? {
        val extras = intent?.extras ?: return null
        val eventType = extras.getString("eventType") ?: return null
        val notificationId = extras.getString("notificationId") ?: return null
        val payload = linkedMapOf<String, Any?>(
            "eventType" to eventType,
            "notificationId" to notificationId,
        )
        extras.getString("packageName")?.let { payload["packageName"] = it }
        extras.getString("appName")?.let { payload["appName"] = it }
        extras.getString("title")?.let { payload["title"] = it }
        extras.getString("bodyPreview")?.let { payload["bodyPreview"] = it }
        extras.getString("postedAt")?.let { payload["postedAt"] = it }
        extras.getString("removedAt")?.let { payload["removedAt"] = it }
        if (extras.containsKey("isDismissible")) {
            payload["isDismissible"] = extras.getBoolean("isDismissible")
        }
        if (extras.containsKey("isOpenable")) {
            payload["isOpenable"] = extras.getBoolean("isOpenable")
        }
        return payload
    }

    private fun openFile(path: String): Boolean {
        val contentUri = if (path.startsWith("content://")) Uri.parse(path) else null
        val file = if (contentUri == null) File(path) else null
        if (file != null && (!file.exists() || !file.isFile)) {
            Log.w(tag, "Requested file does not exist: $path")
            return false
        }

        val uri = contentUri ?: try {
            FileProvider.getUriForFile(
                this,
                "${applicationContext.packageName}.clipboard.fileprovider",
                file!!,
            )
        } catch (e: IllegalArgumentException) {
            Log.e(tag, "Failed to create content Uri for $path", e)
            return false
        }

        val mimeType = contentResolver.getType(uri)
            ?: file?.let { resolveMimeType(it, uri) }
            ?: "*/*"
        val intent =
            Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, mimeType)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }

        return try {
            startActivity(Intent.createChooser(intent, file?.name ?: "Open download"))
            true
        } catch (e: ActivityNotFoundException) {
            Log.w(tag, "No activity could open file mimeType=$mimeType path=$path", e)
            false
        } catch (e: Exception) {
            Log.e(tag, "Failed to launch open-file intent for $path", e)
            false
        }
    }

    private fun prepareIncomingDownload(fileName: String): Map<String, String> {
        val safeName = sanitizeDownloadFileName(fileName)
        val displayName = resolveAvailableDownloadName(safeName)
        val stagingDirectory = File(filesDir, "incoming-downloads").apply { mkdirs() }
        val stagingFile = File(stagingDirectory, "${UUID.randomUUID()}.part")
        return mapOf(
            "stagingPath" to stagingFile.absolutePath,
            "displayName" to displayName,
            "displayPath" to "Downloads/$displayName",
        )
    }

    private fun publishIncomingDownload(
        stagingPath: String,
        fileName: String,
        mediaType: String,
    ): Map<String, String> {
        val stagingDirectory = File(filesDir, "incoming-downloads").canonicalFile
        val stagingFile = File(stagingPath).canonicalFile
        if (!stagingFile.path.startsWith("${stagingDirectory.path}${File.separator}") ||
            !stagingFile.isFile) {
            throw IllegalArgumentException("Invalid incoming download staging path")
        }

        val displayName = resolveAvailableDownloadName(sanitizeDownloadFileName(fileName))
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, displayName)
            put(MediaStore.Downloads.MIME_TYPE, mediaType)
            put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
            put(MediaStore.Downloads.IS_PENDING, 1)
        }
        val uri = contentResolver.insert(
            MediaStore.Downloads.EXTERNAL_CONTENT_URI,
            values,
        ) ?: throw IllegalStateException("Could not create Downloads entry")

        try {
            contentResolver.openOutputStream(uri, "w")?.use { output ->
                stagingFile.inputStream().use { input -> input.copyTo(output) }
            } ?: throw IllegalStateException("Could not open Downloads entry")
            values.clear()
            values.put(MediaStore.Downloads.IS_PENDING, 0)
            contentResolver.update(uri, values, null, null)
            stagingFile.delete()
            return mapOf(
                "contentUri" to uri.toString(),
                "displayName" to displayName,
                "displayPath" to "Downloads/$displayName",
            )
        } catch (e: Exception) {
            contentResolver.delete(uri, null, null)
            throw e
        }
    }

    private fun resolveAvailableDownloadName(fileName: String): String {
        if (!downloadNameExists(fileName)) {
            return fileName
        }
        val dotIndex = fileName.lastIndexOf('.')
        val hasExtension = dotIndex > 0 && dotIndex < fileName.length - 1
        val stem = if (hasExtension) fileName.substring(0, dotIndex) else fileName
        val extension = if (hasExtension) fileName.substring(dotIndex) else ""
        for (index in 1..999) {
            val candidate = "$stem ($index)$extension"
            if (!downloadNameExists(candidate)) {
                return candidate
            }
        }
        return "$stem (${System.currentTimeMillis()})$extension"
    }

    private fun downloadNameExists(fileName: String): Boolean {
        contentResolver.query(
            MediaStore.Downloads.EXTERNAL_CONTENT_URI,
            arrayOf(MediaStore.Downloads._ID),
            "${MediaStore.Downloads.DISPLAY_NAME} = ? AND ${MediaStore.Downloads.RELATIVE_PATH} = ?",
            arrayOf(fileName, "${Environment.DIRECTORY_DOWNLOADS}/"),
            null,
        )?.use { cursor -> return cursor.moveToFirst() }
        return false
    }

    private fun sanitizeDownloadFileName(fileName: String): String {
        val basename = fileName.split('/', '\\').lastOrNull { it.isNotBlank() } ?: fileName
        val cleaned = basename.replace(Regex("[<>:\"/\\\\|?*]"), "_").trim()
        return if (cleaned.isBlank() || cleaned.all { it == '.' }) "incoming.bin" else cleaned
    }

    private fun getPublicDownloadsDirectory(): String? {
        return try {
            Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
                .absolutePath
        } catch (e: Exception) {
            Log.e(tag, "Failed to resolve public Downloads directory", e)
            null
        }
    }

    private fun resolveMimeType(file: File, uri: Uri): String {
        val contentResolverType = contentResolver.getType(uri)
        if (!contentResolverType.isNullOrBlank()) {
            return contentResolverType
        }

        val extension = file.extension.lowercase()
        if (extension.isNotEmpty()) {
            val fromExtension = MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension)
            if (!fromExtension.isNullOrBlank()) {
                return fromExtension
            }
        }

        return "*/*"
    }
}
