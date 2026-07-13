package com.example.app_flutter

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
            val intent = Intent("com.example.app_flutter.CLIPBOARD_CHANGED")
            intent.setPackage(packageName)
            payload.forEach { (key, value) -> intent.putExtra(key, value) }
            sendBroadcast(intent)

            val message = when (payload["contentType"]) {
                "image/png" -> "Image sent to Rift"
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
