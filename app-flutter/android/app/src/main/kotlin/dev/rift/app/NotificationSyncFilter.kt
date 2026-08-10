package dev.rift.app

import android.app.Notification

internal object NotificationSyncFilter {
    fun shouldIgnoreAsMedia(
        isSyncTestNotification: Boolean,
        category: String?,
        hasMediaSession: Boolean,
    ): Boolean {
        if (isSyncTestNotification) {
            return false
        }

        return hasMediaSession || category == Notification.CATEGORY_TRANSPORT
    }
}
