package com.example.app_flutter

import android.content.Context
import android.content.Intent
import org.json.JSONArray
import org.json.JSONObject

object NotificationSyncRelay {
    const val broadcastAction = "com.example.app_flutter.NOTIFICATION_SYNC_EVENT"

    private const val prefsName = "rift_notification_sync"
    private const val pendingEventsKey = "pending_events"
    private const val activeNotificationIdsKey = "active_notification_ids"

    fun queueAndBroadcast(context: Context, payload: Map<String, Any?>) {
        queueEvent(context, payload)
        context.sendBroadcast(buildIntent(payload))
    }

    fun drainPendingEvents(context: Context): List<Map<String, Any?>> {
        val prefs = context.getSharedPreferences(prefsName, Context.MODE_PRIVATE)
        val raw = prefs.getString(pendingEventsKey, null)
        prefs.edit().remove(pendingEventsKey).apply()
        if (raw.isNullOrBlank()) {
            return emptyList()
        }

        val result = mutableListOf<Map<String, Any?>>()
        val entries = JSONArray(raw)
        for (index in 0 until entries.length()) {
            val item = entries.optJSONObject(index) ?: continue
            result += jsonObjectToMap(item)
        }
        return result
    }

    fun acknowledgeDeliveredEvent(context: Context, payload: Map<String, Any?>) {
        val prefs = context.getSharedPreferences(prefsName, Context.MODE_PRIVATE)
        val existingRaw = prefs.getString(pendingEventsKey, null) ?: return
        val entries = JSONArray(existingRaw)
        val target = mapToJsonObject(payload).toString()
        val remaining = JSONArray()
        var removed = false
        for (index in 0 until entries.length()) {
            val item = entries.optJSONObject(index) ?: continue
            val serialized = item.toString()
            if (!removed && serialized == target) {
                removed = true
                continue
            }
            remaining.put(item)
        }

        prefs.edit().apply {
            if (remaining.length() == 0) {
                remove(pendingEventsKey)
            } else {
                putString(pendingEventsKey, remaining.toString())
            }
        }.apply()
    }

    fun hasSeenNotification(context: Context, notificationId: String): Boolean {
        val prefs = context.getSharedPreferences(prefsName, Context.MODE_PRIVATE)
        return prefs.getStringSet(activeNotificationIdsKey, emptySet())
            ?.contains(notificationId) == true
    }

    fun markNotificationActive(context: Context, notificationId: String) {
        mutateActiveNotificationIds(context) { ids -> ids += notificationId }
    }

    fun markNotificationRemoved(context: Context, notificationId: String) {
        mutateActiveNotificationIds(context) { ids -> ids -= notificationId }
    }

    private fun mutateActiveNotificationIds(
        context: Context,
        mutate: (MutableSet<String>) -> Unit,
    ) {
        val prefs = context.getSharedPreferences(prefsName, Context.MODE_PRIVATE)
        val current = prefs.getStringSet(activeNotificationIdsKey, emptySet())?.toMutableSet()
            ?: mutableSetOf()
        mutate(current)
        prefs.edit().putStringSet(activeNotificationIdsKey, current).apply()
    }

    private fun queueEvent(context: Context, payload: Map<String, Any?>) {
        val prefs = context.getSharedPreferences(prefsName, Context.MODE_PRIVATE)
        val existingRaw = prefs.getString(pendingEventsKey, null)
        val entries =
            if (existingRaw.isNullOrBlank()) {
                JSONArray()
            } else {
                JSONArray(existingRaw)
            }
        entries.put(mapToJsonObject(payload))
        prefs.edit().putString(pendingEventsKey, entries.toString()).apply()
    }

    private fun buildIntent(payload: Map<String, Any?>): Intent {
        return Intent(broadcastAction).apply {
            payload.forEach { (key, value) ->
                when (value) {
                    is String -> putExtra(key, value)
                    is Boolean -> putExtra(key, value)
                    is Int -> putExtra(key, value)
                    is Long -> putExtra(key, value)
                    is Double -> putExtra(key, value)
                }
            }
        }
    }

    private fun mapToJsonObject(payload: Map<String, Any?>): JSONObject {
        val obj = JSONObject()
        payload.forEach { (key, value) -> obj.put(key, value) }
        return obj
    }

    private fun jsonObjectToMap(obj: JSONObject): Map<String, Any?> {
        val result = linkedMapOf<String, Any?>()
        val keys = obj.keys()
        while (keys.hasNext()) {
            val key = keys.next()
            result[key] = obj.opt(key)
        }
        return result
    }
}
