package dev.rift.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

class RiftBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        if (intent?.action != Intent.ACTION_BOOT_COMPLETED &&
            intent?.action != Intent.ACTION_MY_PACKAGE_REPLACED
        ) {
            return
        }
        val enabled = context.getSharedPreferences(
            RiftDaemonService.preferencesName,
            Context.MODE_PRIVATE,
        ).getBoolean(RiftDaemonService.backgroundEnabledKey, false)
        if (enabled) {
            RiftDaemonService.start(context)
        }
    }
}
