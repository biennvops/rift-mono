package com.example.app_flutter

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.graphics.BitmapFactory
import android.net.Uri
import android.util.Base64
import android.util.Log
import androidx.core.content.FileProvider
import java.io.File
import java.io.ByteArrayOutputStream
import java.util.UUID

object AndroidClipboardCodec {
    private const val TAG = "RiftClipboardCodec"
    private const val MaxClipboardBytes = 32 * 1024 * 1024

    fun encodePrimaryClip(context: Context, clipboard: ClipboardManager): Map<String, String>? {
        val clip = clipboard.primaryClip ?: return null
        if (clip.itemCount <= 0) {
            return null
        }

        val item = clip.getItemAt(0)
        val uri = item.uri
        if (uri != null) {
            encodeImageUri(context, clip, uri)?.let { payload -> return payload }
        }

        val text = item.coerceToText(context)?.toString()
        if (!text.isNullOrEmpty()) {
            return mapOf("text" to text)
        }

        return null
    }

    private fun encodeImageUri(
        context: Context,
        clip: ClipData,
        uri: Uri,
    ): Map<String, String>? {
        val mediaType =
            context.contentResolver.getType(uri)
                ?: clip.description.getMimeTypeCount()
                    .takeIf { it > 0 }
                    ?.let { clip.description.getMimeType(0) }
        if (mediaType == null) {
            return null
        }

        if (!mediaType.startsWith("image/", ignoreCase = true)) {
            return null
        }

        val pngBytes = if (mediaType.equals("image/png", ignoreCase = true)) {
            context.contentResolver.openInputStream(uri)?.use { input ->
                input.readBytes()
            }
        } else {
            context.contentResolver.openInputStream(uri)?.use { input ->
                val bitmap = BitmapFactory.decodeStream(input)
                if (bitmap == null) {
                    Log.w(TAG, "Failed to decode clipboard image mimeType=$mediaType")
                    null
                } else {
                    ByteArrayOutputStream().use { output ->
                        bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, output)
                        output.toByteArray()
                    }
                }
            }
        } ?: return null

        if (pngBytes.size > MaxClipboardBytes) {
            Log.w(TAG, "Clipboard image payload too large: ${pngBytes.size} bytes")
            return null
        }

        return mapOf(
            "contentType" to "image/png",
            "contentBase64" to Base64.encodeToString(pngBytes, Base64.NO_WRAP),
        )
    }

    fun applyClipboardPayload(
        context: Context,
        clipboard: ClipboardManager,
        contentType: String,
        contentBase64: String,
    ): Boolean {
        val bytes = try {
            Base64.decode(contentBase64, Base64.DEFAULT)
        } catch (e: IllegalArgumentException) {
            Log.w(TAG, "Invalid base64 clipboard payload", e)
            return false
        }

        return when (contentType) {
            "text/plain", "clipboard" -> {
                val text = bytes.toString(Charsets.UTF_8)
                clipboard.setPrimaryClip(ClipData.newPlainText("Rift Clipboard", text))
                true
            }
            "image/png" -> {
                val uri = writeClipboardImage(context, bytes) ?: return false
                clipboard.setPrimaryClip(
                    ClipData.newUri(
                        context.contentResolver,
                        "Rift Image",
                        uri,
                    )
                )
                true
            }
            else -> {
                Log.w(TAG, "Unsupported clipboard content type=$contentType")
                false
            }
        }
    }

    private fun writeClipboardImage(context: Context, bytes: ByteArray): Uri? {
        return try {
            val clipboardDir = File(context.cacheDir, "clipboard")
            if (!clipboardDir.exists()) {
                clipboardDir.mkdirs()
            }

            clipboardDir.listFiles()?.forEach { file ->
                if (file.isFile) {
                    file.delete()
                }
            }

            val outputFile = File(clipboardDir, "${UUID.randomUUID()}.png")
            outputFile.writeBytes(bytes)
            FileProvider.getUriForFile(
                context,
                "${context.packageName}.clipboard.fileprovider",
                outputFile,
            )
        } catch (e: Exception) {
            Log.e(TAG, "Failed to write clipboard image", e)
            null
        }
    }
}
