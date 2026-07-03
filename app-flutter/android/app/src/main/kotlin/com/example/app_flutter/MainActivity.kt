package com.example.app_flutter

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity() {
    private val CHANNEL = "com.biennvops.rift/clipboard"
    private var channel: MethodChannel? = null

    private val clipboardReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            val text = intent?.getStringExtra("text")
            if (text != null) {
                channel?.invokeMethod("onClipboardChanged", mapOf("text" to text))
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        
        channel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "startService" -> {
                    val serviceIntent = Intent(this, ClipboardForegroundService::class.java)
                    ContextCompat.startForegroundService(this, serviceIntent)
                    result.success(true)
                }
                "stopService" -> {
                    val serviceIntent = Intent(this, ClipboardForegroundService::class.java)
                    stopService(serviceIntent)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
        
        val filter = IntentFilter("com.example.app_flutter.CLIPBOARD_CHANGED")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(clipboardReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(clipboardReceiver, filter)
        }
    }

    override fun onDestroy() {
        val serviceIntent = Intent(this, ClipboardForegroundService::class.java)
        stopService(serviceIntent)
        unregisterReceiver(clipboardReceiver)
        super.onDestroy()
    }
}
