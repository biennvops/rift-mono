package dev.rift.app

import android.app.Notification
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Log
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

class RiftNotificationListenerService : NotificationListenerService() {
    companion object {
        private const val tag = "RiftNotifListener"
        private const val syncTestExtraKey = "dev.rift.app.SYNC_TEST_NOTIFICATION"

        @Volatile
        private var activeInstance: RiftNotificationListenerService? = null

        fun performAction(notificationId: String, action: String): Map<String, Any?> {
            val listener = activeInstance
                ?: return mapOf(
                    "success" to false,
                    "failureReason" to "CapabilityUnavailable",
                    "message" to "Android notification listener is unavailable.",
                )
            return listener.executeAction(notificationId, action)
        }
    }

    override fun onListenerConnected() {
        super.onListenerConnected()
        activeInstance = this
        Log.i(tag, "Notification listener connected")
        getActiveNotifications()?.forEach(::onNotificationPosted)
    }

    override fun onListenerDisconnected() {
        if (activeInstance === this) {
            activeInstance = null
        }
        super.onListenerDisconnected()
        Log.i(tag, "Notification listener disconnected")
    }

    override fun onDestroy() {
        if (activeInstance === this) {
            activeInstance = null
        }
        super.onDestroy()
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        if (isIgnoredOwnNotification(sbn)) {
            return
        }
        if (shouldIgnoreNotification(sbn)) {
            cleanUpIgnoredNotificationIfTracked(sbn)
            return
        }

        val payload = buildPostedPayload(sbn) ?: return
        RiftBackgroundHost.sendNativeEvent(this, payload)
        Log.d(
            tag,
            "Notification ${payload["eventType"]} from ${sbn.packageName} key=${sbn.key}",
        )
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification) {
        if (isIgnoredOwnNotification(sbn)) {
            return
        }
        if (shouldIgnoreNotification(sbn)) {
            cleanUpIgnoredNotificationIfTracked(sbn)
            return
        }

        emitRemovedNotification(sbn.key)
        Log.d(tag, "Notification removed from ${sbn.packageName} key=${sbn.key}")
    }

    private fun shouldIgnoreNotification(sbn: StatusBarNotification): Boolean {
        val notification = sbn.notification
        val hasMediaSession =
            notification.extras?.containsKey(Notification.EXTRA_MEDIA_SESSION) == true
        val ignored = NotificationSyncFilter.shouldIgnoreAsMedia(
            isSyncTestNotification = isSyncTestNotification(sbn),
            category = notification.category,
            hasMediaSession = hasMediaSession,
        )
        if (ignored) {
            val reason = if (hasMediaSession) "mediaSession" else "transportCategory"
            Log.d(
                tag,
                "Ignoring Android media notification package=${sbn.packageName} " +
                    "key=${sbn.key} reason=$reason",
            )
        }
        return ignored
    }

    private fun cleanUpIgnoredNotificationIfTracked(sbn: StatusBarNotification) {
        if (!NotificationSyncRelay.hasSeenNotification(this, sbn.key)) {
            return
        }
        Log.d(
            tag,
            "Removing previously synced media notification package=${sbn.packageName} " +
                "key=${sbn.key}",
        )
        emitRemovedNotification(sbn.key)
    }

    private fun emitRemovedNotification(notificationId: String) {
        NotificationSyncRelay.markNotificationRemoved(this, notificationId)
        val payload =
            mapOf(
                "eventType" to "removed",
                "notificationId" to notificationId,
                "removedAt" to formatUtcTimestamp(System.currentTimeMillis()),
            )
        RiftBackgroundHost.sendNativeEvent(this, payload)
    }

    private fun isIgnoredOwnNotification(sbn: StatusBarNotification): Boolean =
        sbn.packageName == packageName && !isSyncTestNotification(sbn)

    private fun buildPostedPayload(sbn: StatusBarNotification): Map<String, Any?>? {
        val extras = sbn.notification.extras ?: return null
        val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString()?.trim()
        val body =
            (
                extras.getCharSequence(Notification.EXTRA_BIG_TEXT)
                    ?: extras.getCharSequence(Notification.EXTRA_TEXT)
            )?.toString()?.trim()
        val appName =
            try {
                packageManager.getApplicationLabel(
                    packageManager.getApplicationInfo(sbn.packageName, 0),
                ).toString()
            } catch (_: Exception) {
                sbn.packageName
            }
        val notificationId = sbn.key
        val eventType =
            if (NotificationSyncRelay.hasSeenNotification(this, notificationId)) {
                "updated"
            } else {
                NotificationSyncRelay.markNotificationActive(this, notificationId)
                "posted"
            }
        return mapOf(
            "eventType" to eventType,
            "notificationId" to notificationId,
            "sourcePlatform" to "android",
            "packageName" to sbn.packageName,
            "appName" to appName,
            "title" to title,
            "bodyPreview" to body,
            "postedAt" to formatUtcTimestamp(sbn.postTime.takeIf { it > 0L } ?: System.currentTimeMillis()),
            "isDismissible" to sbn.isClearable,
            "isOpenable" to false,
        )
    }

    private fun executeAction(notificationId: String, action: String): Map<String, Any?> {
        if (action == "open") {
            return mapOf(
                "success" to false,
                "failureReason" to "CapabilityUnavailable",
                "message" to "Android remote notification open is not supported.",
            )
        }
        if (action != "dismiss") {
            return mapOf(
                "success" to false,
                "failureReason" to "ProtocolError",
                "message" to "Unknown notification action.",
            )
        }
        val notification = getActiveNotifications()?.firstOrNull { it.key == notificationId }
            ?: return mapOf(
                "success" to false,
                "failureReason" to "CapabilityUnavailable",
                "message" to "Android notification no longer exists.",
            )
        if (!notification.isClearable) {
            return mapOf(
                "success" to false,
                "failureReason" to "PolicyDenied",
                "message" to "Android notification is not clearable.",
            )
        }
        return try {
            cancelNotification(notification.key)
            mapOf("success" to true)
        } catch (_: Exception) {
            mapOf(
                "success" to false,
                "failureReason" to "PeerRejected",
                "message" to "Android notification dismiss failed.",
            )
        }
    }

    private fun isSyncTestNotification(sbn: StatusBarNotification): Boolean =
        sbn.notification.extras?.getBoolean(syncTestExtraKey, false) == true

    private fun formatUtcTimestamp(epochMillis: Long): String {
        val formatter =
            SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US).apply {
                timeZone = TimeZone.getTimeZone("UTC")
            }
        return formatter.format(Date(epochMillis))
    }
}
