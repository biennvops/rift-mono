package dev.rift.app

import java.util.concurrent.CountDownLatch
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RuntimeShutdownFinalizerTest {
    @Test
    fun finalizesOnlyOnce() {
        var finalizationCalls = 0
        val finalizer = RuntimeShutdownFinalizer { finalizationCalls += 1 }

        assertTrue(finalizer.finalizeOnce())
        assertFalse(finalizer.finalizeOnce())
        assertTrue(finalizer.isFinalized())
        assertEquals(1, finalizationCalls)
    }

    @Test
    fun acknowledgmentAndFallbackRaceFinalizesOnlyOnce() {
        val callersReady = CountDownLatch(2)
        val start = CountDownLatch(1)
        var finalizationCalls = 0
        val finalizer = RuntimeShutdownFinalizer { finalizationCalls += 1 }
        val acknowledgment = Thread {
            callersReady.countDown()
            start.await()
            finalizer.finalizeOnce()
        }
        val fallback = Thread {
            callersReady.countDown()
            start.await()
            finalizer.finalizeOnce()
        }

        acknowledgment.start()
        fallback.start()
        callersReady.await()
        start.countDown()
        acknowledgment.join()
        fallback.join()

        assertEquals(1, finalizationCalls)
        assertTrue(finalizer.isFinalized())
    }
}
