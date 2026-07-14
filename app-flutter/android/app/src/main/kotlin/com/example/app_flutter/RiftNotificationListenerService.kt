package com.example.app_flutter

import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Log

class RiftNotificationListenerService : NotificationListenerService() {
    companion object {
        private const val tag = "RiftNotifListener"
    }

    override fun onListenerConnected() {
        super.onListenerConnected()
        Log.i(tag, "Notification listener connected")
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        if (sbn.packageName == packageName) {
            return
        }
        Log.d(tag, "Notification posted from ${sbn.packageName} key=${sbn.key}")
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification) {
        if (sbn.packageName == packageName) {
            return
        }
        Log.d(tag, "Notification removed from ${sbn.packageName} key=${sbn.key}")
    }
}
