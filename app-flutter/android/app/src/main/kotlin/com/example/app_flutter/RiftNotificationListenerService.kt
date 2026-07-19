package com.example.app_flutter

import android.app.Notification
import android.app.PendingIntent
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
        private const val syncTestExtraKey = "com.example.app_flutter.SYNC_TEST_NOTIFICATION"
        @Volatile
        private var activeInstance: RiftNotificationListenerService? = null

        fun performAction(notificationId: String, action: String): Map<String, Any?> {
            val service = activeInstance
                ?: return failure("CapabilityUnavailable", "Notification access is unavailable.")
            val notification = service.activeNotifications
                ?.firstOrNull { it.key == notificationId }
                ?: return failure("CapabilityUnavailable", "The notification is no longer active.")

            return when (action) {
                "dismiss" -> {
                    if (!notification.isClearable) {
                        failure("PolicyDenied", "The notification cannot be dismissed.")
                    } else {
                        service.cancelNotification(notification.key)
                        mapOf("success" to true)
                    }
                }
                "open" -> {
                    val contentIntent = notification.notification.contentIntent
                        ?: return failure("CapabilityUnavailable", "The notification cannot be opened.")
                    try {
                        contentIntent.send()
                        mapOf("success" to true)
                    } catch (error: PendingIntent.CanceledException) {
                        failure("CapabilityUnavailable", error.message ?: "The notification action expired.")
                    }
                }
                else -> failure("ProtocolError", "Unknown notification action '$action'.")
            }
        }

        private fun failure(reason: String, message: String): Map<String, Any?> =
            mapOf(
                "success" to false,
                "failureReason" to reason,
                "message" to message,
            )
    }

    override fun onListenerConnected() {
        super.onListenerConnected()
        activeInstance = this
        Log.i(tag, "Notification listener connected")
    }

    override fun onListenerDisconnected() {
        if (activeInstance === this) {
            activeInstance = null
        }
        super.onListenerDisconnected()
    }

    override fun onDestroy() {
        if (activeInstance === this) {
            activeInstance = null
        }
        super.onDestroy()
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        if (sbn.packageName == packageName && !isSyncTestNotification(sbn)) {
            return
        }
        val payload = buildPostedPayload(sbn) ?: return
        NotificationSyncRelay.queueAndBroadcast(this, payload)
        Log.d(
            tag,
            "Notification ${payload["eventType"]} from ${sbn.packageName} key=${sbn.key}",
        )
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification) {
        if (sbn.packageName == packageName && !isSyncTestNotification(sbn)) {
            return
        }
        NotificationSyncRelay.markNotificationRemoved(this, sbn.key)
        val payload =
            mapOf(
                "eventType" to "removed",
                "notificationId" to sbn.key,
                "removedAt" to formatUtcTimestamp(System.currentTimeMillis()),
            )
        NotificationSyncRelay.queueAndBroadcast(this, payload)
        Log.d(tag, "Notification removed from ${sbn.packageName} key=${sbn.key}")
    }

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
            "packageName" to sbn.packageName,
            "appName" to appName,
            "title" to title,
            "bodyPreview" to body,
            "postedAt" to formatUtcTimestamp(sbn.postTime.takeIf { it > 0L } ?: System.currentTimeMillis()),
            "isDismissible" to sbn.isClearable,
            "isOpenable" to (sbn.notification.contentIntent != null),
        )
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
