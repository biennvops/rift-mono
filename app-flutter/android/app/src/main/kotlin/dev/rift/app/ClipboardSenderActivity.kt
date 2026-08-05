package dev.rift.app

import android.app.Activity
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.widget.Toast

class ClipboardSenderActivity : Activity() {
    companion object {
        private const val notificationIntentRouteKey = "rift.notification.route"
        private const val notificationIntentPayloadPrefix = "rift.notification.payload."
        private const val clipboardSendRoute = "clipboard.send"
    }

    private var hasHandled = false
    private val handler = Handler(Looper.getMainLooper())

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        overridePendingTransition(0, 0)
    }

    override fun onResume() {
        super.onResume()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) {
            handler.postDelayed({
                handleClipboardOnce("windowFocus")
            }, 180)
        }
    }

    override fun onDestroy() {
        handler.removeCallbacksAndMessages(null)
        super.onDestroy()
    }

    private fun handleClipboardOnce(source: String) {
        if (hasHandled) {
            return
        }

        hasHandled = true
        val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        val payload = AndroidClipboardCodec.encodePrimaryClip(this, clipboard)

        if (payload != null) {
            if (MainActivity.isClipboardRelayReady) {
                val intent = Intent("dev.rift.app.CLIPBOARD_CHANGED")
                intent.setPackage(packageName)
                payload.forEach { (key, value) -> intent.putExtra(key, value) }
                sendBroadcast(intent)
            } else {
                val launchIntent = Intent(this, MainActivity::class.java).apply {
                    flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                        Intent.FLAG_ACTIVITY_SINGLE_TOP or
                        Intent.FLAG_ACTIVITY_CLEAR_TOP
                    putExtra(notificationIntentRouteKey, clipboardSendRoute)
                    payload.forEach { (key, value) ->
                        putExtra("$notificationIntentPayloadPrefix$key", value)
                    }
                }
                startActivity(launchIntent)
            }

            val message = when (payload["contentType"]) {
                "image/png" -> "Image sent to Rift"
                "text/plain" -> "Text sent to Rift"
                else -> "Sent to Rift"
            }
            Toast.makeText(this, message, Toast.LENGTH_SHORT).show()
        } else {
            Log.w("RiftTile", "Clipboard payload is empty or unsupported")
            Toast.makeText(this, "Clipboard is empty or unsupported", Toast.LENGTH_SHORT).show()
        }

        closeSenderSurface()
    }

    private fun closeSenderSurface() {
        finish()
        overridePendingTransition(0, 0)
    }
}
