package dev.rift.app

import java.util.LinkedHashMap
import java.util.concurrent.Executor
import java.util.concurrent.RejectedExecutionException

internal data class EncodedMediaArtwork(
    val mimeType: String,
    val dataBase64: String,
    val byteSize: Int,
    val sha256: String,
) {
    fun asMap(): Map<String, Any?> = mapOf(
        "mediaType" to mimeType,
        "dataBase64" to dataBase64,
        "byteSize" to byteSize,
        "sha256" to sha256,
    )
}

internal class BoundedArtworkCache<K, V : Any>(
    private val maxEntries: Int,
) {
    private val entries = object : LinkedHashMap<K, V>(maxEntries, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<K, V>?): Boolean =
            size > maxEntries
    }

    init {
        require(maxEntries > 0)
    }

    fun get(key: K): V? = entries[key]

    fun put(key: K, value: V) {
        entries[key] = value
    }

    fun clear() {
        entries.clear()
    }

    fun size(): Int = entries.size
}

internal data class ArtworkCacheLookup<V : Any>(
    val isCached: Boolean,
    val value: V?,
)

internal class ArtworkPipeline<K, S, V : Any>(
    cacheEntries: Int,
    private val executor: Executor,
    private val completionDispatcher: ((() -> Unit) -> Unit),
    private val encoder: (S) -> V?,
    private val onRequest: () -> Unit = {},
    private val onCacheHit: () -> Unit = {},
    private val onEncodeStarted: () -> Unit = {},
    private val onEncodeCompleted: (V) -> Unit = {},
    private val onDiscarded: () -> Unit = {},
) {
    private data class Listener<V : Any>(
        val onReady: (V) -> Unit,
        val onFailure: () -> Unit,
    )

    private class Work<V : Any> {
        val listenersByRequester = LinkedHashMap<String, Listener<V>>()
    }

    private val cache = BoundedArtworkCache<K, V>(cacheEntries)
    private val inFlightByKey = HashMap<K, Work<V>>()

    @Volatile
    private var active = true

    fun lookup(key: K): ArtworkCacheLookup<V> {
        val value = cache.get(key)
            ?: return ArtworkCacheLookup(isCached = false, value = null)
        onCacheHit()
        return ArtworkCacheLookup(isCached = true, value = value)
    }

    fun retainRequesterForKey(requesterId: String, key: K?) {
        inFlightByKey.forEach { (inFlightKey, work) ->
            if (inFlightKey != key) {
                work.listenersByRequester.remove(requesterId)
            }
        }
    }

    fun request(
        key: K,
        source: S,
        requesterId: String,
        onReady: (V) -> Unit,
        onFailure: () -> Unit = {},
    ) {
        if (!active) return
        onRequest()
        retainRequesterForKey(requesterId, key)

        val cached = cache.get(key)
        if (cached != null) {
            onCacheHit()
            onReady(cached)
            return
        }

        val listener = Listener(onReady = onReady, onFailure = onFailure)
        val existing = inFlightByKey[key]
        if (existing != null) {
            existing.listenersByRequester[requesterId] = listener
            return
        }

        val work = Work<V>()
        work.listenersByRequester[requesterId] = listener
        inFlightByKey[key] = work
        try {
            executor.execute {
                if (!active) {
                    onDiscarded()
                    return@execute
                }
                onEncodeStarted()
                val encoded = try {
                    encoder(source)
                } catch (_: Exception) {
                    null
                }
                if (encoded != null) {
                    onEncodeCompleted(encoded)
                }
                completionDispatcher {
                    complete(key, work, encoded)
                }
            }
        } catch (_: RejectedExecutionException) {
            if (inFlightByKey[key] === work) {
                inFlightByKey.remove(key)
            }
            onDiscarded()
            onFailure()
        }
    }

    fun request(
        key: K,
        source: S,
        requesterId: String,
        onReady: (V) -> Unit,
    ) {
        request(key, source, requesterId, onReady, {})
    }

    fun removeRequester(requesterId: String) {
        retainRequesterForKey(requesterId, null)
    }

    fun close() {
        active = false
        inFlightByKey.clear()
        cache.clear()
    }

    internal fun cacheSize(): Int = cache.size()

    internal fun inFlightCount(): Int = inFlightByKey.size

    private fun complete(key: K, work: Work<V>, encoded: V?) {
        if (!active || inFlightByKey[key] !== work) {
            onDiscarded()
            return
        }
        inFlightByKey.remove(key)
        if (encoded == null) {
            work.listenersByRequester.values.forEach { listener ->
                listener.onFailure()
            }
            return
        }
        cache.put(key, encoded)

        val listeners = work.listenersByRequester.values.toList()
        if (listeners.isEmpty()) {
            onDiscarded()
            return
        }
        listeners.forEach { listener -> listener.onReady(encoded) }
    }
}
