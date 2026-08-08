package dev.rift.app

import org.junit.Assert.assertEquals
import org.junit.Test

class NotificationSyncRelayTest {
    @Test
    fun noTrackedNotificationsAreStale() {
        assertEquals(
            emptySet<String>(),
            NotificationSyncRelay.staleNotificationIds(
                setOf("a", "b"),
                setOf("a", "b"),
            ),
        )
    }

    @Test
    fun missingActiveNotificationIsStale() {
        assertEquals(
            setOf("a"),
            NotificationSyncRelay.staleNotificationIds(
                setOf("a", "b"),
                setOf("b"),
            ),
        )
    }

    @Test
    fun newActiveNotificationIsNotStale() {
        assertEquals(
            emptySet<String>(),
            NotificationSyncRelay.staleNotificationIds(
                setOf("a"),
                setOf("a", "c"),
            ),
        )
    }

    @Test
    fun allMissingNotificationsAreStale() {
        assertEquals(
            setOf("a", "b"),
            NotificationSyncRelay.staleNotificationIds(
                setOf("a", "b"),
                emptySet(),
            ),
        )
    }
}
