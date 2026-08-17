package dev.rift.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ForegroundSyncNotificationTest {
    @Test
    fun parsesValidStatus() {
        val status = ForegroundSyncStatusParser.parse(
            mapOf(
                "runtimeState" to "ready",
                "trustedPeerCount" to 3,
                "connectedPeerCount" to 2,
                "connectedPeerNames" to listOf("Fedora Workstation", "MacBook Pro"),
            ),
        )

        assertEquals(
            ForegroundSyncStatus(
                runtimeState = ForegroundSyncRuntimeState.READY,
                trustedPeerCount = 3,
                connectedPeerCount = 2,
                connectedPeerNames = listOf("Fedora Workstation", "MacBook Pro"),
            ),
            status,
        )
    }

    @Test
    fun rejectsImpossibleCountsAndNames() {
        val invalidPayloads = listOf(
            mapOf(
                "runtimeState" to "ready",
                "trustedPeerCount" to -1,
                "connectedPeerCount" to 0,
                "connectedPeerNames" to emptyList<String>(),
            ),
            mapOf(
                "runtimeState" to "ready",
                "trustedPeerCount" to 1,
                "connectedPeerCount" to 2,
                "connectedPeerNames" to listOf("one", "two"),
            ),
            mapOf(
                "runtimeState" to "unknown",
                "trustedPeerCount" to 0,
                "connectedPeerCount" to 0,
                "connectedPeerNames" to emptyList<String>(),
            ),
            mapOf(
                "runtimeState" to "ready",
                "trustedPeerCount" to 1,
                "connectedPeerCount" to 1,
                "connectedPeerNames" to listOf("  "),
            ),
            mapOf(
                "runtimeState" to "ready",
                "trustedPeerCount" to 1,
                "connectedPeerCount" to 1,
                "connectedPeerNames" to listOf("x".repeat(49)),
            ),
        )

        invalidPayloads.forEach { payload ->
            assertNull(ForegroundSyncStatusParser.parse(payload))
        }
    }

    @Test
    fun rejectsMoreThanFiveNames() {
        val payload = mapOf(
            "runtimeState" to "ready",
            "trustedPeerCount" to 6,
            "connectedPeerCount" to 6,
            "connectedPeerNames" to List(6) { index -> "Device $index" },
        )

        assertNull(ForegroundSyncStatusParser.parse(payload))
    }

    @Test
    fun formatsStartingAndReconnectingStates() {
        val starting = ForegroundSyncStatus(
            runtimeState = ForegroundSyncRuntimeState.STARTING,
            trustedPeerCount = 0,
            connectedPeerCount = 0,
            connectedPeerNames = emptyList(),
        ).notificationCopy()
        val reconnecting = ForegroundSyncStatus(
            runtimeState = ForegroundSyncRuntimeState.RECONNECTING,
            trustedPeerCount = 2,
            connectedPeerCount = 1,
            connectedPeerNames = listOf("Phone"),
        ).notificationCopy()

        assertEquals("Rift is starting", starting.title)
        assertEquals("Preparing background sync", starting.body)
        assertEquals("Rift is reconnecting", reconnecting.title)
        assertEquals("Trusted device sync will resume automatically", reconnecting.body)
    }

    @Test
    fun formatsReadyPeerStatesAndInboxLines() {
        val noPeers = ForegroundSyncStatus(
            runtimeState = ForegroundSyncRuntimeState.READY,
            trustedPeerCount = 0,
            connectedPeerCount = 0,
            connectedPeerNames = emptyList(),
        ).notificationCopy()
        val offline = ForegroundSyncStatus(
            runtimeState = ForegroundSyncRuntimeState.READY,
            trustedPeerCount = 1,
            connectedPeerCount = 0,
            connectedPeerNames = emptyList(),
        ).notificationCopy()
        val onePeer = ForegroundSyncStatus(
            runtimeState = ForegroundSyncRuntimeState.READY,
            trustedPeerCount = 1,
            connectedPeerCount = 1,
            connectedPeerNames = listOf("MacBook Pro"),
        ).notificationCopy()
        val multiplePeers = ForegroundSyncStatus(
            runtimeState = ForegroundSyncRuntimeState.READY,
            trustedPeerCount = 4,
            connectedPeerCount = 4,
            connectedPeerNames = listOf("MacBook Pro", "Fedora Workstation", "ThinkPad"),
        ).notificationCopy()

        assertEquals("Pair a device to start syncing", noPeers.body)
        assertEquals("Waiting for trusted devices", offline.body)
        assertEquals("Connected to MacBook Pro", onePeer.title)
        assertEquals("Rift background sync is active", onePeer.body)
        assertEquals("Connected to 4 devices", multiplePeers.title)
        assertEquals(
            "MacBook Pro · Fedora Workstation · ThinkPad · +1 more",
            multiplePeers.body,
        )
        assertEquals(
            listOf("MacBook Pro", "Fedora Workstation", "ThinkPad", "+1 more"),
            multiplePeers.expandedLines,
        )
        assertTrue(multiplePeers.expandedLines.isNotEmpty())
    }
}
