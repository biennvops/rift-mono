package dev.rift.app

import android.app.Notification
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NotificationSyncFilterTest {
    @Test
    fun mediaSessionNotificationIsIgnored() {
        assertTrue(
            NotificationSyncFilter.shouldIgnoreAsMedia(
                isSyncTestNotification = false,
                category = null,
                hasMediaSession = true,
            ),
        )
    }

    @Test
    fun transportCategoryNotificationIsIgnored() {
        assertTrue(
            NotificationSyncFilter.shouldIgnoreAsMedia(
                isSyncTestNotification = false,
                category = Notification.CATEGORY_TRANSPORT,
                hasMediaSession = false,
            ),
        )
    }

    @Test
    fun normalMessageNotificationIsNotIgnored() {
        assertFalse(
            NotificationSyncFilter.shouldIgnoreAsMedia(
                isSyncTestNotification = false,
                category = Notification.CATEGORY_MESSAGE,
                hasMediaSession = false,
            ),
        )
    }

    @Test
    fun syncTestNotificationOverridesMediaSessionFilter() {
        assertFalse(
            NotificationSyncFilter.shouldIgnoreAsMedia(
                isSyncTestNotification = true,
                category = null,
                hasMediaSession = true,
            ),
        )
    }

    @Test
    fun syncTestNotificationOverridesTransportCategoryFilter() {
        assertFalse(
            NotificationSyncFilter.shouldIgnoreAsMedia(
                isSyncTestNotification = true,
                category = Notification.CATEGORY_TRANSPORT,
                hasMediaSession = false,
            ),
        )
    }

    @Test
    fun nullCategoryWithoutMediaSessionIsNotIgnored() {
        assertFalse(
            NotificationSyncFilter.shouldIgnoreAsMedia(
                isSyncTestNotification = false,
                category = null,
                hasMediaSession = false,
            ),
        )
    }
}
