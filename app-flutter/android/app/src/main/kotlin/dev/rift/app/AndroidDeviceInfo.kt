package dev.rift.app

import android.content.Context
import android.os.Build
import android.provider.Settings

object AndroidDeviceInfo {
    fun asMap(context: Context): Map<String, String> {
        val configuredName = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N_MR1) {
            Settings.Global.getString(
                context.contentResolver,
                Settings.Global.DEVICE_NAME,
            )
        } else {
            null
        }
        val displayName = sequenceOf(configuredName, Build.MODEL)
            .mapNotNull(::normalize)
            .firstOrNull()

        return buildMap {
            if (displayName != null) {
                put("displayName", displayName)
            }
            put("platform", "android")
        }
    }

    private fun normalize(value: String?): String? {
        val normalized = value
            ?.filterNot(Char::isISOControl)
            ?.trim()
            ?.take(128)
        return normalized?.takeIf(String::isNotEmpty)
    }
}
