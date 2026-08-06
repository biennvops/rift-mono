package dev.rift.app

import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import android.os.PowerManager

object AndroidDeviceStatus {
    fun asMap(context: Context): Map<String, Any?> {
        val battery = context.registerReceiver(
            null,
            IntentFilter(Intent.ACTION_BATTERY_CHANGED),
        )
        val level = battery?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
        val scale = battery?.getIntExtra(BatteryManager.EXTRA_SCALE, -1) ?: -1
        val percent = if (level >= 0 && scale > 0) {
            ((level * 100.0) / scale).toInt().coerceIn(0, 100)
        } else {
            null
        }
        val chargingState = when (
            battery?.getIntExtra(BatteryManager.EXTRA_STATUS, BatteryManager.BATTERY_STATUS_UNKNOWN)
        ) {
            BatteryManager.BATTERY_STATUS_CHARGING -> "charging"
            BatteryManager.BATTERY_STATUS_DISCHARGING -> "discharging"
            BatteryManager.BATTERY_STATUS_FULL -> "full"
            BatteryManager.BATTERY_STATUS_NOT_CHARGING -> "notCharging"
            else -> "unknown"
        }
        val powerSource = when (
            battery?.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0)
        ) {
            BatteryManager.BATTERY_PLUGGED_USB -> "usb"
            BatteryManager.BATTERY_PLUGGED_AC,
            BatteryManager.BATTERY_PLUGGED_WIRELESS -> "ac"
            else -> "battery"
        }
        val powerManager = context.getSystemService(Context.POWER_SERVICE) as PowerManager
        return mapOf(
            "batteryPercent" to percent,
            "chargingState" to chargingState,
            "powerSource" to powerSource,
            "lowPowerMode" to powerManager.isPowerSaveMode,
            "sourcePlatform" to "android",
        )
    }
}
