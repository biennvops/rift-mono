package dev.rift.app

internal class RuntimeShutdownFinalizer(
    private val finalizeRuntime: () -> Unit,
) {
    private var finalized = false

    fun finalizeOnce(): Boolean {
        synchronized(this) {
            if (finalized) {
                return false
            }
            finalized = true
        }
        finalizeRuntime()
        return true
    }

    fun isFinalized(): Boolean = synchronized(this) { finalized }
}
