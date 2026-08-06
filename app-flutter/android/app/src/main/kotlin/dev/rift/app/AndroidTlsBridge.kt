package dev.rift.app

import android.util.Base64
import android.util.Log
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.net.InetSocketAddress
import java.security.KeyFactory
import java.security.KeyStore
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
import java.util.ArrayDeque
import java.util.concurrent.atomic.AtomicInteger
import javax.net.ssl.KeyManagerFactory
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLServerSocket
import javax.net.ssl.SSLSocket
import javax.net.ssl.TrustManager
import javax.net.ssl.X509TrustManager

class AndroidTlsBridge {
    companion object {
        private const val tag = "RiftTlsBridge"
        private const val maxQueuedAcceptedConnections = 8
        private const val queuedConnectionTimeoutSeconds = 10L
    }

    private data class QueuedConnection(
        val response: Map<String, Any>,
        val connectionId: Int,
        var expiry: ScheduledFuture<*>? = null,
    )

    private val executor = Executors.newCachedThreadPool()
    private val expiryExecutor = Executors.newSingleThreadScheduledExecutor()
    // Bumped whenever the owning daemon isolate tears down the server. Replies
    // guarded by an older generation are dropped instead of being posted to a
    // dead isolate port, which is a fatal engine check (did_send).
    private val generation = AtomicInteger(0)
    private val nextConnectionId = AtomicInteger(1)
    private val connections = ConcurrentHashMap<Int, SSLSocket>()
    private var server: SSLServerSocket? = null
    private var pendingAccept: MethodChannel.Result? = null
    private val acceptedConnections = ArrayDeque<QueuedConnection>()

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "startServer" -> startServer(call.arguments as? Map<*, *>, result)
            "accept" -> accept(result)
            "connect" -> connect(call.arguments as? Map<*, *>, result)
            "read" -> read(call.arguments as? Map<*, *>, result)
            "write" -> write(call.arguments as? Map<*, *>, result)
            "close" -> close(call.arguments as? Map<*, *>, result)
            "stopServer" -> stopServer(result)
            else -> result.notImplemented()
        }
    }

    fun dispose() {
        stopServerInternal()
        executor.shutdownNow()
        expiryExecutor.shutdownNow()
    }

    private fun startServer(arguments: Map<*, *>?, result: MethodChannel.Result) {
        try {
            val certPem = arguments?.get("certificatePem") as? String
                ?: throw IllegalArgumentException("certificatePem is required")
            val privateKeyPem = arguments["privateKeyPem"] as? String
                ?: throw IllegalArgumentException("privateKeyPem is required")
            val port = (arguments["port"] as? Number)?.toInt()
                ?: throw IllegalArgumentException("port is required")
            stopServerInternal()
            val context = buildContext(certPem, privateKeyPem)
            val socket = context.serverSocketFactory.createServerSocket() as SSLServerSocket
            socket.reuseAddress = true
            socket.bind(InetSocketAddress("0.0.0.0", port))
            socket.needClientAuth = true
            server = socket
            executor.execute { acceptLoop(socket) }
            result.success(mapOf("port" to socket.localPort))
        } catch (error: Throwable) {
            result.error("start_server_failed", error.message, null)
        }
    }

    private fun accept(result: MethodChannel.Result) {
        if (server == null) {
            result.error("server_not_started", "TLS server is not running", null)
            return
        }
        synchronized(this) {
            if (acceptedConnections.isNotEmpty()) {
                val queued = acceptedConnections.removeFirst()
                queued.expiry?.cancel(false)
                result.success(queued.response)
                return
            }
            if (pendingAccept != null) {
                result.error("accept_pending", "Only one accept operation may be pending", null)
                return
            }
            pendingAccept = result
        }
    }

    private fun acceptLoop(listener: SSLServerSocket) {
        val gen = generation.get()
        while (!listener.isClosed && generation.get() == gen) {
            var socket: SSLSocket? = null
            var id: Int? = null
            try {
                socket = listener.accept() as SSLSocket
                socket.useClientMode = false
                socket.soTimeout = 10_000
                socket.startHandshake()
                socket.soTimeout = 0
                if (generation.get() != gen || listener.isClosed) {
                    socket.close()
                    return
                }
                id = register(socket)
                val certificate = socket.session.peerCertificates.firstOrNull() as? X509Certificate
                val response = mapOf(
                    "connectionId" to id,
                    "peerCertificateBase64" to Base64.encodeToString(
                        certificate?.encoded ?: ByteArray(0),
                        Base64.NO_WRAP,
                    ),
                    "remoteAddress" to socket.inetAddress.hostAddress,
                    "remotePort" to socket.port,
                )
                if (generation.get() != gen || listener.isClosed) {
                    connections.remove(id)
                    socket.close()
                    return
                }
                var closeBecauseQueueFull = false
                val callback = synchronized(this) {
                    if (generation.get() != gen || listener.isClosed) {
                        null
                    } else {
                        val current = pendingAccept
                        if (current != null) {
                            pendingAccept = null
                        } else if (acceptedConnections.size >= maxQueuedAcceptedConnections) {
                            closeBecauseQueueFull = true
                            null
                        } else {
                            val queued = QueuedConnection(response, id)
                            acceptedConnections.addLast(queued)
                            queued.expiry = expiryExecutor.schedule(
                                { expireQueuedConnection(id) },
                                queuedConnectionTimeoutSeconds,
                                TimeUnit.SECONDS,
                            )
                            null
                        }
                        current
                    }
                }
                if (generation.get() != gen || listener.isClosed) {
                    connections.remove(id)
                    socket.close()
                    return
                }
                if (closeBecauseQueueFull) {
                    connections.remove(id)
                    runCatching { socket.close() }
                    Log.w(tag, "Closing accepted TLS connection because the Dart accept queue is full")
                    continue
                }
                callback?.success(response)
            } catch (error: Throwable) {
                id?.let(connections::remove)
                runCatching { socket?.close() }
                if (listener.isClosed) return
                Log.e(tag, "Inbound TLS connection failed", error)
            }
        }
    }

    private fun connect(arguments: Map<*, *>?, result: MethodChannel.Result) {
        val gen = generation.get()
        executor.execute {
            if (generation.get() != gen) return@execute
            var socket: SSLSocket? = null
            var id: Int? = null
            try {
                val host = arguments?.get("host") as? String
                    ?: throw IllegalArgumentException("host is required")
                val port = (arguments["port"] as? Number)?.toInt()
                    ?: throw IllegalArgumentException("port is required")
                val certPem = arguments["certificatePem"] as? String
                    ?: throw IllegalArgumentException("certificatePem is required")
                val privateKeyPem = arguments["privateKeyPem"] as? String
                    ?: throw IllegalArgumentException("privateKeyPem is required")
                val context = buildContext(certPem, privateKeyPem)
                socket = context.socketFactory.createSocket() as SSLSocket
                socket.useClientMode = true
                socket.soTimeout = 10_000
                socket.connect(InetSocketAddress(host, port), 10_000)
                socket.startHandshake()
                socket.soTimeout = 0
                if (generation.get() != gen) {
                    socket.close()
                    return@execute
                }
                id = register(socket)
                val certificate = socket.session.peerCertificates.firstOrNull() as? X509Certificate
                val response = mapOf(
                    "connectionId" to id,
                    "peerCertificateBase64" to Base64.encodeToString(
                        certificate?.encoded ?: ByteArray(0),
                        Base64.NO_WRAP,
                    ),
                    "remoteAddress" to socket.inetAddress.hostAddress,
                    "remotePort" to socket.port,
                )
                if (generation.get() != gen) {
                    connections.remove(id)
                    socket.close()
                    return@execute
                }
                result.success(response)
            } catch (error: Throwable) {
                id?.let(connections::remove)
                runCatching { socket?.close() }
                if (generation.get() == gen) {
                    result.error("connect_failed", error.message, null)
                }
            }
        }
    }

    private fun read(arguments: Map<*, *>?, result: MethodChannel.Result) {
        val id = (arguments?.get("connectionId") as? Number)?.toInt()
        val socket = id?.let(connections::get)
        if (socket == null) {
            result.error("connection_not_found", "TLS connection is not available", null)
            return
        }
        val gen = generation.get()
        executor.execute {
            try {
                val buffer = ByteArray(16 * 1024)
                val count = socket.inputStream.read(buffer)
                if (generation.get() != gen) return@execute
                if (count < 0) {
                    result.success(mapOf("eof" to true))
                } else {
                    result.success(
                        mapOf(
                            "eof" to false,
                            "dataBase64" to Base64.encodeToString(buffer.copyOf(count), Base64.NO_WRAP),
                        ),
                    )
                }
            } catch (error: Throwable) {
                if (generation.get() == gen) {
                    result.error("read_failed", error.message, null)
                }
            }
        }
    }

    private fun write(arguments: Map<*, *>?, result: MethodChannel.Result) {
        val id = (arguments?.get("connectionId") as? Number)?.toInt()
        val data = arguments?.get("dataBase64") as? String
        val socket = id?.let(connections::get)
        if (socket == null || data == null) {
            result.error("invalid_write", "connectionId and dataBase64 are required", null)
            return
        }
        val gen = generation.get()
        executor.execute {
            try {
                val bytes = Base64.decode(data, Base64.DEFAULT)
                socket.outputStream.write(bytes)
                socket.outputStream.flush()
                if (generation.get() == gen) {
                    result.success(true)
                }
            } catch (error: Throwable) {
                if (generation.get() == gen) {
                    result.error("write_failed", error.message, null)
                }
            }
        }
    }

    private fun close(arguments: Map<*, *>?, result: MethodChannel.Result) {
        val id = (arguments?.get("connectionId") as? Number)?.toInt()
        val socket = id?.let(connections::remove)
        try {
            socket?.close()
            result.success(true)
        } catch (error: Throwable) {
            result.error("close_failed", error.message, null)
        }
    }

    private fun stopServer(result: MethodChannel.Result) {
        stopServerInternal()
        result.success(true)
    }

    private fun stopServerInternal() {
        generation.incrementAndGet()
        synchronized(this) {
            // Do not reply to a pending accept here: the daemon isolate that
            // issued it may already be dead, and replying to a dead response
            // port is a fatal engine check (did_send). The stale Dart future
            // is owned by the old isolate and simply goes away with it.
            pendingAccept = null
            acceptedConnections.forEach { it.expiry?.cancel(false) }
            acceptedConnections.clear()
        }
        server?.close()
        server = null
        connections.values.forEach { socket -> runCatching { socket.close() } }
        connections.clear()
    }

    private fun expireQueuedConnection(connectionId: Int) {
        val removed = synchronized(this) {
            val queued = acceptedConnections.firstOrNull { it.connectionId == connectionId }
            if (queued != null) {
                acceptedConnections.remove(queued)
            }
            queued
        }
        if (removed != null) {
            connections.remove(connectionId)?.let { socket -> runCatching { socket.close() } }
            Log.w(tag, "Expired queued TLS connection before Dart accepted it")
        }
    }

    private fun register(socket: SSLSocket): Int {
        val id = nextConnectionId.getAndIncrement()
        connections[id] = socket
        return id
    }

    private fun buildContext(certificatePem: String, privateKeyPem: String): SSLContext {
        val certificate = parseCertificate(certificatePem)
        val keyBytes = if (privateKeyPem.contains("BEGIN EC PRIVATE KEY")) {
            wrapEcPrivateKey(decodePem(privateKeyPem, "EC PRIVATE KEY"))
        } else {
            decodePem(privateKeyPem, "PRIVATE KEY")
        }
        val privateKey = KeyFactory.getInstance("EC")
            .generatePrivate(java.security.spec.PKCS8EncodedKeySpec(keyBytes))
        val keyStore = KeyStore.getInstance(KeyStore.getDefaultType())
        keyStore.load(null, null)
        keyStore.setKeyEntry("rift", privateKey, CharArray(0), arrayOf(certificate))
        val keyManagers = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm())
        keyManagers.init(keyStore, CharArray(0))
        val trustManager = object : X509TrustManager {
            override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
            override fun checkClientTrusted(chain: Array<X509Certificate>, authType: String) = Unit
            override fun checkServerTrusted(chain: Array<X509Certificate>, authType: String) = Unit
        }
        return SSLContext.getInstance("TLS").apply {
            init(keyManagers.keyManagers, arrayOf<TrustManager>(trustManager), null)
        }
    }

    private fun parseCertificate(pem: String): X509Certificate {
        val bytes = decodePem(pem, "CERTIFICATE")
        return CertificateFactory.getInstance("X.509")
            .generateCertificate(bytes.inputStream()) as X509Certificate
    }

    private fun decodePem(pem: String, label: String): ByteArray {
        val body = pem
            .replace("-----BEGIN $label-----", "")
            .replace("-----END $label-----", "")
            .replace(Regex("\\s"), "")
        return Base64.decode(body, Base64.DEFAULT)
    }

    private fun wrapEcPrivateKey(sec1: ByteArray): ByteArray {
        val algorithm = byteArrayOf(
            0x30, 0x13, 0x06, 0x07, 0x2a, 0x86.toByte(), 0x48, 0xce.toByte(),
            0x3d, 0x02, 0x01, 0x06, 0x08, 0x2a, 0x86.toByte(), 0x48,
            0xce.toByte(), 0x3d, 0x03, 0x01, 0x07,
        )
        val version = byteArrayOf(0x02, 0x01, 0x00)
        val privateKey = byteArrayOf(0x04) + encodeDerLength(sec1.size) + sec1
        val contents = version + algorithm + privateKey
        return byteArrayOf(0x30) + encodeDerLength(contents.size) + contents
    }

    private fun encodeDerLength(length: Int): ByteArray = when {
        length < 0x80 -> byteArrayOf(length.toByte())
        length <= 0xff -> byteArrayOf(0x81.toByte(), length.toByte())
        else -> byteArrayOf(0x82.toByte(), (length shr 8).toByte(), length.toByte())
    }
}
