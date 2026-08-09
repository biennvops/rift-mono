package dev.rift.app

import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.Drawable
import android.util.Log
import java.io.ByteArrayOutputStream
import java.security.MessageDigest
import java.util.LinkedHashMap
import kotlin.math.max
import kotlin.math.roundToInt

internal data class NotificationAppIconPayload(
    val dataBase64: String,
    val byteSize: Int,
    val sha256: String,
) {
    fun asMap(): Map<String, Any?> = linkedMapOf(
        "mediaType" to "image/png",
        "dataBase64" to dataBase64,
        "byteSize" to byteSize,
        "sha256" to sha256,
    )

    companion object {
        fun fromPngBytes(bytes: ByteArray): NotificationAppIconPayload? {
            if (bytes.isEmpty() || bytes.size > NotificationIconLimits.maxRawBytes) {
                return null
            }

            val digest = MessageDigest.getInstance("SHA-256").digest(bytes)
                .joinToString(separator = "") { byte ->
                    "%02x".format(byte.toInt() and 0xff)
                }
            return NotificationAppIconPayload(
                dataBase64 = java.util.Base64.getEncoder().encodeToString(bytes),
                byteSize = bytes.size,
                sha256 = digest,
            )
        }
    }
}

internal class NotificationAppIconCache(
    private val maxEntries: Int = NotificationIconLimits.maxCacheEntries,
) {
    private val entries = object : LinkedHashMap<String, NotificationAppIconPayload>(
        maxEntries,
        0.75f,
        true,
    ) {
        override fun removeEldestEntry(
            eldest: MutableMap.MutableEntry<String, NotificationAppIconPayload>?,
        ): Boolean = size > maxEntries
    }

    @Synchronized
    fun get(key: String): NotificationAppIconPayload? = entries[key]

    @Synchronized
    fun put(key: String, value: NotificationAppIconPayload) {
        entries[key] = value
    }

    @Synchronized
    internal fun size(): Int = entries.size
}

internal object NotificationIconLimits {
    const val maxRawBytes = 131072
    const val maxCacheEntries = 64
    const val renderSize = 128
}

internal class NotificationAppIconExtractor(
    private val packageManager: PackageManager,
) {
    companion object {
        private const val tag = "RiftNotifIcon"
    }

    private val cache = NotificationAppIconCache()

    fun iconForPackage(packageName: String): Map<String, Any?>? {
        return try {
            val packageInfo = packageManager.getPackageInfo(packageName, 0)
            val cacheKey = "$packageName:${packageInfo.lastUpdateTime}"
            cache.get(cacheKey)?.asMap() ?: renderAndCache(packageName, cacheKey)
        } catch (error: Throwable) {
            Log.d(tag, "Could not extract application icon for $packageName", error)
            null
        }
    }

    private fun renderAndCache(
        packageName: String,
        cacheKey: String,
    ): Map<String, Any?>? {
        val drawable = packageManager.getApplicationIcon(packageName)
        val bitmap = Bitmap.createBitmap(
            NotificationIconLimits.renderSize,
            NotificationIconLimits.renderSize,
            Bitmap.Config.ARGB_8888,
        )
        return try {
            val canvas = Canvas(bitmap)
            val intrinsicWidth = drawable.intrinsicWidth.takeIf { it > 0 }
                ?: NotificationIconLimits.renderSize
            val intrinsicHeight = drawable.intrinsicHeight.takeIf { it > 0 }
                ?: NotificationIconLimits.renderSize
            val scale = minOf(
                NotificationIconLimits.renderSize.toFloat() / intrinsicWidth,
                NotificationIconLimits.renderSize.toFloat() / intrinsicHeight,
            )
            val width = max(1, (intrinsicWidth * scale).roundToInt())
            val height = max(1, (intrinsicHeight * scale).roundToInt())
            val left = (NotificationIconLimits.renderSize - width) / 2
            val top = (NotificationIconLimits.renderSize - height) / 2
            drawDrawable(drawable, canvas, left, top, left + width, top + height)

            val output = ByteArrayOutputStream()
            if (!bitmap.compress(Bitmap.CompressFormat.PNG, 100, output)) {
                return null
            }
            val payload = NotificationAppIconPayload.fromPngBytes(output.toByteArray())
                ?: return null
            cache.put(cacheKey, payload)
            payload.asMap()
        } finally {
            bitmap.recycle()
        }
    }

    private fun drawDrawable(
        drawable: Drawable,
        canvas: Canvas,
        left: Int,
        top: Int,
        right: Int,
        bottom: Int,
    ) {
        drawable.setBounds(left, top, right, bottom)
        drawable.draw(canvas)
    }
}
