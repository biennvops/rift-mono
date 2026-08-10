package dev.rift.app

import android.content.Context
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

object RiftBackgroundHost {
    const val serviceBridgeChannelName = "rift/android/background_bridge"
    const val uiRpcChannelName = "rift/android/service_rpc"
    const val uiEventsChannelName = "rift/android/service_rpc_events"

    private const val maxQueuedMessages = 256
    private var serviceBridge: MethodChannel? = null
    private var serviceContext: Context? = null
    private var serviceReady = false
    private var uiEventSink: EventChannel.EventSink? = null
    private val queuedUiRequests = ArrayDeque<String>()
    private val queuedNativeEvents = ArrayDeque<Map<String, Any?>>()
    private var nativeCommandHandler:
        ((String, Any?, MethodChannel.Result) -> Unit)? = null

    @Synchronized
    fun attachService(
        context: Context,
        engine: FlutterEngine,
        commandHandler: (String, Any?, MethodChannel.Result) -> Unit,
    ) {
        serviceContext = context.applicationContext
        nativeCommandHandler = commandHandler
        serviceReady = false
        serviceBridge = MethodChannel(
            engine.dartExecutor.binaryMessenger,
            serviceBridgeChannelName,
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "backgroundReady" -> {
                        serviceReady = true
                        flushQueuedMessages()
                        serviceContext?.let { context ->
                            NotificationSyncRelay.drainPendingEvents(context).forEach {
                                serviceBridge?.invokeMethod("nativeEvent", it, ignoreResult)
                            }
                        }
                        result.success(true)
                    }
                    "daemonMessage" -> {
                        val message = call.arguments as? String
                        if (message != null) {
                            publishDaemonMessage(message)
                        }
                        result.success(true)
                    }
                    else -> {
                        val handler = nativeCommandHandler
                        if (handler == null) {
                            result.error("service_unavailable", "Rift background service is not ready", null)
                        } else {
                            handler(call.method, call.arguments, result)
                        }
                    }
                }
            }
        }
    }

    @Synchronized
    fun detachService() {
        serviceReady = false
        serviceContext = null
        serviceBridge = null
        nativeCommandHandler = null
    }

    @Synchronized
    fun attachUi(context: Context) {
        RiftDaemonService.start(context)
    }

    @Synchronized
    fun detachUi() {
        uiEventSink = null
    }

    @Synchronized
    fun setUiEventSink(sink: EventChannel.EventSink?) {
        uiEventSink = sink
    }

    @Synchronized
    fun sendUiRpc(context: Context, message: String, result: MethodChannel.Result) {
        attachUi(context)
        val bridge = serviceBridge
        if (!serviceReady || bridge == null) {
            enqueue(queuedUiRequests, message)
            result.success(true)
            return
        }
        bridge.invokeMethod("uiRequest", message, result)
    }

    @Synchronized
    fun sendNativeEvent(context: Context, event: Map<String, Any?>) {
        val bridge = serviceBridge
        if (!serviceReady || bridge == null) {
            if (event["notificationId"] is String) {
                NotificationSyncRelay.queueEvent(context, event)
            } else {
                enqueue(queuedNativeEvents, event)
            }
            return
        }
        bridge.invokeMethod("nativeEvent", event, ignoreResult)
    }

    @Synchronized
    fun sendUiNativeCommand(
        method: String,
        arguments: Any?,
        result: MethodChannel.Result,
    ) {
        val handler = nativeCommandHandler
        if (handler == null) {
            result.error("service_unavailable", "Rift background service is not ready", null)
            return
        }
        handler(method, arguments, result)
    }

    @Synchronized
    fun flushQueuedMessages() {
        val bridge = serviceBridge ?: return
        if (!serviceReady) return

        while (queuedUiRequests.isNotEmpty()) {
            bridge.invokeMethod("uiRequest", queuedUiRequests.removeFirst(), ignoreResult)
        }
        while (queuedNativeEvents.isNotEmpty()) {
            bridge.invokeMethod("nativeEvent", queuedNativeEvents.removeFirst(), ignoreResult)
        }
    }

    private fun publishDaemonMessage(message: String) {
        uiEventSink?.success(message)
    }

    private fun <T> enqueue(queue: ArrayDeque<T>, value: T) {
        if (queue.size >= maxQueuedMessages) {
            queue.removeFirst()
        }
        queue.addLast(value)
    }

    private val ignoreResult = object : MethodChannel.Result {
        override fun success(result: Any?) = Unit
        override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) = Unit
        override fun notImplemented() = Unit
    }
}
