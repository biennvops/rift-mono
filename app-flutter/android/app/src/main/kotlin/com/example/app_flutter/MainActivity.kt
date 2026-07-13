package com.example.app_flutter

import android.content.BroadcastReceiver
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.util.Log
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
            val contentType = intent?.getStringExtra("contentType")
            val contentBase64 = intent?.getStringExtra("contentBase64")
            when {
                text != null -> {
                    Log.i(TAG, "Received clipboard broadcast length=${text.length}")
                    channel?.invokeMethod("onClipboardChanged", mapOf("text" to text))
                }
                contentType != null && contentBase64 != null -> {
                    Log.i(
                        TAG,
                        "Received clipboard broadcast contentType=$contentType base64Length=${contentBase64.length}",
                    )
                    channel?.invokeMethod(
                        "onClipboardChanged",
                        mapOf(
                            "contentType" to contentType,
                            "contentBase64" to contentBase64,
                        ),
                    )
                }
                else -> {
                    Log.i(TAG, "Received clipboard broadcast with no supported payload")
                }
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
                "setClipboardContent" -> {
                    val args = call.arguments as? Map<*, *>
                    val contentType = args?.get("contentType") as? String
                    val contentBase64 = args?.get("contentBase64") as? String
                    if (contentType == null || contentBase64 == null) {
                        result.error("invalid_args", "contentType and contentBase64 are required", null)
                    } else {
                        val clipboard =
                            getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                        val applied = AndroidClipboardCodec.applyClipboardPayload(
                            this,
                            clipboard,
                            contentType,
                            contentBase64,
                        )
                        result.success(applied)
                    }
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
