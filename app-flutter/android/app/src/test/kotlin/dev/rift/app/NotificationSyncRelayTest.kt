package dev.rift.app

import org.json.JSONArray
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
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

    @Test
    fun nestedIconSurvivesQueueJsonRoundTrip() {
        val payload: Map<String, Any?> = mapOf(
            "eventType" to "posted",
            "notificationId" to "n1",
            "postedAt" to "2026-07-15T08:30:00.000Z",
            "icon" to mapOf(
                "mediaType" to "image/png",
                "dataBase64" to "AQID",
                "byteSize" to 3,
                "sha256" to "0000000000000000000000000000000000000000000000000000000000000000",
            ),
        )

        val stored = JSONArray()
            .put(NotificationSyncRelay.mapToJsonObject(payload))
            .toString()
        val restoredEntries = JSONArray(stored)
        val restored = NotificationSyncRelay.jsonObjectToMap(
            restoredEntries.getJSONObject(0),
        )

        assertEquals(payload, restored)
        assertTrue(restored["icon"] is Map<*, *>)
    }
}
