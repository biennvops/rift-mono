package com.example.app_flutter

import android.app.Activity
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.util.Log
import android.widget.Toast

class ClipboardSenderActivity : Activity() {
    private var hasHandled = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Log.i("RiftTile", "ClipboardSenderActivity onCreate")
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        
        if (hasFocus && !hasHandled) {
            hasHandled = true
            Log.i("RiftTile", "Activity gained focus, reading clipboard...")
            
            val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            val clip = clipboard.primaryClip

            if (clip != null && clip.itemCount > 0) {
                val text = clip.getItemAt(0).coerceToText(this)?.toString()
                if (!text.isNullOrEmpty()) {
                    Log.i("RiftTile", "Broadcasting clipboard text length=${text.length}")
                    val intent = Intent("com.example.app_flutter.CLIPBOARD_CHANGED")
                    intent.setPackage(packageName)
                    intent.putExtra("text", text)
                    sendBroadcast(intent)
                    
                    Toast.makeText(this, "Sent to Rift", Toast.LENGTH_SHORT).show()
                } else {
                    Toast.makeText(this, "Clipboard is empty", Toast.LENGTH_SHORT).show()
                }
            } else {
                Log.w("RiftTile", "Clipboard primary clip is null")
                Toast.makeText(this, "Clipboard is empty", Toast.LENGTH_SHORT).show()
            }

            // Close the activity immediately after reading
            finish()
        }
    }
}
