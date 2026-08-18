package dev.rift.app

internal enum class ForegroundSyncRuntimeState(val wireValue: String) {
    STARTING("starting"),
    READY("ready"),
    RECONNECTING("reconnecting");

    companion object {
        fun fromWireValue(value: String): ForegroundSyncRuntimeState? =
            entries.firstOrNull { it.wireValue == value }
    }
}

internal data class ForegroundSyncStatus(
    val runtimeState: ForegroundSyncRuntimeState,
    val trustedPeerCount: Int,
    val connectedPeerCount: Int,
    val connectedPeerNames: List<String>,
)

internal data class ForegroundSyncNotificationCopy(
    val title: String,
    val body: String,
    val expandedLines: List<String>,
)

internal object ForegroundSyncStatusParser {
    const val maxDisplayedPeerNames = 5
    const val maxPeerNameLength = 48

    fun parse(arguments: Any?): ForegroundSyncStatus? {
        val values = arguments as? Map<*, *> ?: return null
        val runtimeState =
            (values["runtimeState"] as? String)?.let(
                ForegroundSyncRuntimeState::fromWireValue,
            ) ?: return null
        val trustedPeerCount = parseCount(values["trustedPeerCount"]) ?: return null
        val connectedPeerCount = parseCount(values["connectedPeerCount"]) ?: return null
        if (connectedPeerCount > trustedPeerCount) {
            return null
        }

        val names = values["connectedPeerNames"] as? List<*> ?: return null
        if (names.size > maxDisplayedPeerNames || names.size > connectedPeerCount) {
            return null
        }
        val connectedPeerNames = names.map { value ->
            val name = value as? String ?: return null
            if (!isValidName(name)) {
                return null
            }
            name
        }

        return ForegroundSyncStatus(
            runtimeState = runtimeState,
            trustedPeerCount = trustedPeerCount,
            connectedPeerCount = connectedPeerCount,
            connectedPeerNames = connectedPeerNames,
        )
    }

    private fun parseCount(value: Any?): Int? {
        val number = value as? Number ?: return null
        val longValue = number.toLong()
        if (number.toDouble() != longValue.toDouble() ||
            longValue < 0L ||
            longValue > Int.MAX_VALUE
        ) {
            return null
        }
        return longValue.toInt()
    }

    private fun isValidName(name: String): Boolean {
        if (name.isBlank() || name.codePointCount(0, name.length) > maxPeerNameLength) {
            return false
        }

        var offset = 0
        while (offset < name.length) {
            val codePoint = name.codePointAt(offset)
            if (Character.isISOControl(codePoint)) {
                return false
            }
            offset += Character.charCount(codePoint)
        }
        return true
    }
}

internal fun ForegroundSyncStatus.notificationCopy(): ForegroundSyncNotificationCopy {
    return when (runtimeState) {
        ForegroundSyncRuntimeState.STARTING -> ForegroundSyncNotificationCopy(
            title = "Rift is starting",
            body = "Preparing background sync",
            expandedLines = emptyList(),
        )
        ForegroundSyncRuntimeState.RECONNECTING -> ForegroundSyncNotificationCopy(
            title = "Rift is reconnecting",
            body = "Trusted device sync will resume automatically",
            expandedLines = emptyList(),
        )
        ForegroundSyncRuntimeState.READY -> when {
            trustedPeerCount == 0 -> ForegroundSyncNotificationCopy(
                title = "Rift is running",
                body = "Pair a device to start syncing",
                expandedLines = emptyList(),
            )
            connectedPeerCount == 0 -> ForegroundSyncNotificationCopy(
                title = "Rift is running",
                body = "Waiting for trusted devices",
                expandedLines = emptyList(),
            )
            connectedPeerCount == 1 -> ForegroundSyncNotificationCopy(
                title = "Connected to ${connectedPeerNames.firstOrNull() ?: "Trusted device"}",
                body = "Rift background sync is active",
                expandedLines = emptyList(),
            )
            else -> {
                val moreCount = connectedPeerCount - connectedPeerNames.size
                val moreLine = if (moreCount > 0) "+$moreCount more" else null
                val lines = buildList {
                    addAll(connectedPeerNames)
                    if (moreLine != null) add(moreLine)
                }
                ForegroundSyncNotificationCopy(
                    title = "Connected to $connectedPeerCount devices",
                    body = lines.joinToString(" · "),
                    expandedLines = lines,
                )
            }
        }
    }
}
