package com.example.app_flutter

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.util.Log
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity() {
    private val CHANNEL = "com.biennvops.rift/clipboard"
    private val TAG = "RiftMainActivity"
    private var channel: MethodChannel? = null

    private val clipboardReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            val text = intent?.getStringExtra("text")
            if (text != null) {
                Log.i(TAG, "Received clipboard broadcast length=${text.length}")
                channel?.invokeMethod("onClipboardChanged", mapOf("text" to text))
            } else {
                Log.i(TAG, "Received clipboard broadcast with null text")
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        Log.i(TAG, "configureFlutterEngine")
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        
        channel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "startService" -> {
                    Log.i(TAG, "startService requested from Flutter (stubbed)")
                    result.success(true)
                }
                "stopService" -> {
                    Log.i(TAG, "stopService requested from Flutter (stubbed)")
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
        Log.i(TAG, "Clipboard broadcast receiver registered")
    }

    override fun onStart() {
        super.onStart()
        Log.i(TAG, "onStart")
    }

    override fun onResume() {
        super.onResume()
        Log.i(TAG, "onResume")
    }

    override fun onPause() {
        Log.i(TAG, "onPause")
        super.onPause()
    }

    override fun onStop() {
        Log.i(TAG, "onStop")
        super.onStop()
    }

    override fun onDestroy() {
        Log.i(TAG, "onDestroy")
        unregisterReceiver(clipboardReceiver)
        super.onDestroy()
    }
}
