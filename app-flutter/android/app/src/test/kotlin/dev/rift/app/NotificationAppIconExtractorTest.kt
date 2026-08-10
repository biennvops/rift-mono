package dev.rift.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class NotificationAppIconExtractorTest {
    private val pngBytes = java.util.Base64.getDecoder().decode(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==",
    )
    @Test
    fun canonicalPayloadMatchesPngBytes() {
        val payload = NotificationAppIconPayload.fromPngBytes(pngBytes)

        requireNotNull(payload)
        assertEquals(70, payload.byteSize)
        assertEquals(java.util.Base64.getEncoder().encodeToString(pngBytes), payload.dataBase64)
        assertEquals(
            "4ff6ab670a58c14270e034e2090d9a432caa263a14e0a25785386b0c12f880b5",
            payload.sha256,
        )
        assertEquals("image/png", payload.asMap()["mediaType"])
    }

    @Test
    fun oversizedPayloadIsRejected() {
        assertNull(
            NotificationAppIconPayload.fromPngBytes(
                ByteArray(NotificationIconLimits.maxRawBytes + 1),
            ),
        )
    }

    @Test
    fun cacheIsBoundedAndUsesLruEntries() {
        val cache = NotificationAppIconCache(maxEntries = 2)
        val first = requireNotNull(NotificationAppIconPayload.fromPngBytes(pngBytes))
        val second = requireNotNull(NotificationAppIconPayload.fromPngBytes(pngBytes))
        val third = requireNotNull(NotificationAppIconPayload.fromPngBytes(pngBytes))

        cache.put("first", first)
        cache.put("second", second)
        assertTrue(cache.get("first") === first)
        cache.put("third", third)

        assertNull(cache.get("second"))
        assertTrue(cache.get("first") === first)
        assertTrue(cache.get("third") === third)
        assertEquals(2, cache.size())
    }
}
