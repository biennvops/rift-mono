package com.example.app_flutter

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.util.Log

class ClipboardForegroundService : Service() {
    private val tag = "RiftClipboardSvc"
    private var clipboardManager: ClipboardManager? = null
    private var lastBroadcastText: String? = null

    private val clipboardListener = ClipboardManager.OnPrimaryClipChangedListener {
        val clip = clipboardManager?.primaryClip
        Log.i(tag, "Primary clip changed. itemCount=${clip?.itemCount ?: 0}")
        if (clip != null && clip.itemCount > 0) {
            val text = clip.getItemAt(0).coerceToText(this)?.toString()
            if (!text.isNullOrEmpty() && text != lastBroadcastText) {
                lastBroadcastText = text
                Log.i(tag, "Broadcasting clipboard text length=${text.length}")
                val intent = Intent("com.example.app_flutter.CLIPBOARD_CHANGED")
                intent.setPackage(packageName)
                intent.putExtra("text", text)
                sendBroadcast(intent)
            } else {
                Log.i(tag, "Clipboard text ignored. empty=${text.isNullOrEmpty()} duplicate=${text == lastBroadcastText}")
            }
        }
    }

    override fun onCreate() {
        super.onCreate()
        Log.i(tag, "ClipboardForegroundService created")
        createNotificationChannel()
        
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, "rift_clipboard_channel")
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        
        val notification = builder
            .setContentTitle("Rift Clipboard Sync")
            .setContentText("Listening for clipboard changes")
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .build()

        startForeground(1, notification)

        clipboardManager = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        clipboardManager?.addPrimaryClipChangedListener(clipboardListener)
        Log.i(tag, "Clipboard listener registered")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Log.i(tag, "ClipboardForegroundService onStartCommand")
        return START_STICKY
    }

    override fun onDestroy() {
        clipboardManager?.removePrimaryClipChangedListener(clipboardListener)
        Log.i(tag, "ClipboardForegroundService destroyed")
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? {
        return null
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val serviceChannel = NotificationChannel(
                "rift_clipboard_channel",
                "Rift Clipboard Service",
                NotificationManager.IMPORTANCE_LOW
            )
            val manager = getSystemService(NotificationManager::class.java)
            manager?.createNotificationChannel(serviceChannel)
        }
    }
}
