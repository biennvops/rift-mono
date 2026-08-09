package dev.rift.app

import android.content.Context
import android.content.Intent
import org.json.JSONArray
import org.json.JSONObject

object NotificationSyncRelay {
    const val broadcastAction = "dev.rift.app.NOTIFICATION_SYNC_EVENT"

    private const val prefsName = "rift_notification_sync"
    private const val pendingEventsKey = "pending_events"
    private const val activeNotificationIdsKey = "active_notification_ids"
    internal const val maxPendingEvents = 128
    internal const val maxPendingBytes = 1_048_576

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
        val target = eventSignature(payload["eventType"], payload["notificationId"], eventTimestamp(payload))
        if (target == null) {
            return
        }
        val remaining = JSONArray()
        var removed = false
        for (index in 0 until entries.length()) {
            val item = entries.optJSONObject(index) ?: continue
            val signature = eventSignature(
                item.opt("eventType"),
                item.opt("notificationId"),
                eventTimestamp(item),
            )
            // Match on the identifying fields (eventType, notificationId, timestamp)
            // rather than full JSON equality: the broadcast payload is rebuilt from
            // Intent extras and its key order/type coercion may differ from the
            // stored entry, which would otherwise leave the event un-acknowledged
            // and cause a duplicate re-delivery on the next drain.
            if (!removed && signature == target) {
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
        return activeNotificationIds(context).contains(notificationId)
    }

    fun activeNotificationIds(context: Context): Set<String> {
        val prefs = context.getSharedPreferences(prefsName, Context.MODE_PRIVATE)
        return prefs.getStringSet(activeNotificationIdsKey, emptySet())?.toSet()
            ?: emptySet()
    }

    fun markNotificationActive(context: Context, notificationId: String) {
        mutateActiveNotificationIds(context) { ids -> ids += notificationId }
    }

    fun markNotificationRemoved(context: Context, notificationId: String) {
        mutateActiveNotificationIds(context) { ids -> ids -= notificationId }
    }

    internal fun staleNotificationIds(
        trackedNotificationIds: Set<String>,
        eligibleActiveNotificationIds: Set<String>,
    ): Set<String> = trackedNotificationIds - eligibleActiveNotificationIds

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

    fun queueEvent(context: Context, payload: Map<String, Any?>) {
        val prefs = context.getSharedPreferences(prefsName, Context.MODE_PRIVATE)
        val existingRaw = prefs.getString(pendingEventsKey, null)
        val entries =
            if (existingRaw.isNullOrBlank()) {
                JSONArray()
            } else {
                JSONArray(existingRaw)
            }
        entries.put(mapToJsonObject(payload))
        prefs.edit().putString(pendingEventsKey, boundPendingEvents(entries).toString()).apply()
    }

    internal fun boundPendingEvents(entries: JSONArray): JSONArray {
        // Icons are optional presentation data; remove them before trimming events.
        if (entries.length() > maxPendingEvents ||
            serializedByteSize(entries) > maxPendingBytes
        ) {
            for (index in 0 until entries.length()) {
                entries.optJSONObject(index)?.remove("icon")
            }
        }

        while (entries.length() > maxPendingEvents ||
            serializedByteSize(entries) > maxPendingBytes
        ) {
            entries.remove(0)
        }
        return entries
    }

    private fun serializedByteSize(entries: JSONArray): Int =
        entries.toString().toByteArray(Charsets.UTF_8).size

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

    internal fun mapToJsonObject(payload: Map<String, Any?>): JSONObject {
        val obj = JSONObject()
        mapToJsonCompatible(payload).forEach { (key, value) ->
            obj.put(key, toJsonValue(value))
        }
        return obj
    }

    internal fun jsonObjectToMap(obj: JSONObject): Map<String, Any?> {
        val result = linkedMapOf<String, Any?>()
        val keys = obj.keys()
        while (keys.hasNext()) {
            val key = keys.next()
            result[key] = fromJsonValue(obj.opt(key))
        }
        return result
    }

    internal fun mapToJsonCompatible(payload: Map<String, Any?>): Map<String, Any?> =
        payload.mapValuesTo(linkedMapOf()) { (_, value) -> toJsonCompatibleValue(value) }

    internal fun jsonCompatibleToMap(payload: Map<String, Any?>): Map<String, Any?> =
        payload.mapValuesTo(linkedMapOf()) { (_, value) -> fromJsonCompatibleValue(value) }

    private fun toJsonCompatibleValue(value: Any?): Any? = when (value) {
        null -> null
        is JSONObject -> jsonObjectToMap(value)
        is JSONArray -> buildList {
            for (index in 0 until value.length()) {
                add(fromJsonValue(value.opt(index)))
            }
        }
        is Map<*, *> -> linkedMapOf<String, Any?>().also { map ->
            value.forEach { (key, nestedValue) ->
                if (key is String) {
                    map[key] = toJsonCompatibleValue(nestedValue)
                }
            }
        }
        is Iterable<*> -> value.map { toJsonCompatibleValue(it) }
        is String, is Boolean, is Number -> value
        else -> null
    }

    private fun fromJsonCompatibleValue(value: Any?): Any? = when (value) {
        is Map<*, *> -> linkedMapOf<String, Any?>().also { map ->
            value.forEach { (key, nestedValue) ->
                if (key is String) {
                    map[key] = fromJsonCompatibleValue(nestedValue)
                }
            }
        }
        is Iterable<*> -> value.map { fromJsonCompatibleValue(it) }
        else -> value
    }

    private fun toJsonValue(value: Any?): Any? = when (value) {
        null -> JSONObject.NULL
        is Map<*, *> -> JSONObject().also { obj ->
            value.forEach { (key, nestedValue) ->
                if (key is String) {
                    obj.put(key, toJsonValue(nestedValue))
                }
            }
        }
        is Iterable<*> -> JSONArray().also { array ->
            value.forEach { array.put(toJsonValue(it)) }
        }
        is String, is Boolean, is Number -> value
        else -> JSONObject.NULL
    }

    private fun fromJsonValue(value: Any?): Any? = when (value) {
        null, JSONObject.NULL -> null
        is JSONObject -> jsonObjectToMap(value)
        is JSONArray -> buildList {
            for (index in 0 until value.length()) {
                add(fromJsonValue(value.opt(index)))
            }
        }
        else -> value
    }

    // A posted/updated event carries `postedAt`; a removed event carries `removedAt`.
    // Either disambiguates repeated events for the same notification id.
    private fun eventTimestamp(payload: Map<String, Any?>): Any? =
        payload["postedAt"] ?: payload["removedAt"]

    private fun eventTimestamp(obj: JSONObject): Any? =
        obj.opt("postedAt") ?: obj.opt("removedAt")

    private fun eventSignature(eventType: Any?, notificationId: Any?, timestamp: Any?): String? {
        val type = (eventType as? String)?.takeIf { it.isNotEmpty() } ?: return null
        val id = (notificationId as? String)?.takeIf { it.isNotEmpty() } ?: return null
        return "$type\n$id\n${(timestamp as? String).orEmpty()}"
    }
}
