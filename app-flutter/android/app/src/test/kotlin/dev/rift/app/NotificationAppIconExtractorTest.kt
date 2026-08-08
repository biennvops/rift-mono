package dev.rift.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class NotificationAppIconExtractorTest {
    @Test
    fun canonicalPayloadMatchesPngBytes() {
        val bytes = byteArrayOf(1, 2, 3)
        val payload = NotificationAppIconPayload.fromPngBytes(bytes)

        requireNotNull(payload)
        assertEquals(3, payload.byteSize)
        assertEquals("AQID", payload.dataBase64)
        assertEquals(
            "039058c6f2c0cb492c533b0a4d14ef77cc0f78abccced5287d84a1a2011cfb81",
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
        val first = requireNotNull(NotificationAppIconPayload.fromPngBytes(byteArrayOf(1)))
        val second = requireNotNull(NotificationAppIconPayload.fromPngBytes(byteArrayOf(2)))
        val third = requireNotNull(NotificationAppIconPayload.fromPngBytes(byteArrayOf(3)))

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
