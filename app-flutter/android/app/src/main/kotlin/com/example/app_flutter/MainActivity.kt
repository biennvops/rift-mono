package com.example.app_flutter

import android.Manifest
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity() {
    private val CHANNEL = "com.biennvops.rift/clipboard"
    private val PERMISSIONS_CHANNEL = "rift.permissions"
    private val NOTIFICATION_REQUEST_CODE = 4107
    private val TAG = "RiftMainActivity"
    private var channel: MethodChannel? = null
    private var permissionsChannel: MethodChannel? = null
    private var pendingNotificationPermissionResult: MethodChannel.Result? = null

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
        permissionsChannel =
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PERMISSIONS_CHANNEL)
        
        channel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "startService" -> {
                    Log.i(TAG, "startService requested from Flutter")
                    val serviceIntent = Intent(this, ClipboardForegroundService::class.java)
                    ContextCompat.startForegroundService(this, serviceIntent)
                    result.success(true)
                }
                "stopService" -> {
                    Log.i(TAG, "stopService requested from Flutter")
                    val serviceIntent = Intent(this, ClipboardForegroundService::class.java)
                    stopService(serviceIntent)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        permissionsChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "notification.getStatus" -> {
                    result.success(getNotificationPermissionStatus())
                }
                "notification.request" -> {
                    requestNotificationPermission(result)
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

    private fun getNotificationPermissionStatus(): String {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            return "granted"
        }

        return if (
            ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.POST_NOTIFICATIONS,
            ) == PackageManager.PERMISSION_GRANTED
        ) {
            "granted"
        } else {
            "denied"
        }
    }

    private fun requestNotificationPermission(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            result.success(true)
            return
        }

        if (
            ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.POST_NOTIFICATIONS,
            ) == PackageManager.PERMISSION_GRANTED
        ) {
            result.success(true)
            return
        }

        if (pendingNotificationPermissionResult != null) {
            result.error(
                "notification_request_in_progress",
                "A notification permission request is already in progress.",
                null,
            )
            return
        }

        pendingNotificationPermissionResult = result
        ActivityCompat.requestPermissions(
            this,
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            NOTIFICATION_REQUEST_CODE,
        )
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != NOTIFICATION_REQUEST_CODE) {
            return
        }

        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        pendingNotificationPermissionResult?.success(granted)
        pendingNotificationPermissionResult = null
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
        pendingNotificationPermissionResult = null
        super.onDestroy()
    }
}
