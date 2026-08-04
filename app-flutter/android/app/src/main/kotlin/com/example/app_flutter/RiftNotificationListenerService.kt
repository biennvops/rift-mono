package com.example.app_flutter

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
        private const val syncTestExtraKey = "com.example.app_flutter.SYNC_TEST_NOTIFICATION"
    }

    override fun onListenerConnected() {
        super.onListenerConnected()
        Log.i(tag, "Notification listener connected")
        getActiveNotifications()?.forEach(::onNotificationPosted)
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        if (sbn.packageName == packageName && !isSyncTestNotification(sbn)) {
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
        RiftBackgroundHost.sendNativeEvent(this, payload)
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
            "sourcePlatform" to "android",
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
