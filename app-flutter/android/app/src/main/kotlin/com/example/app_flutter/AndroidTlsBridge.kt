package com.example.app_flutter

import android.util.Base64
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.net.InetSocketAddress
import java.security.KeyFactory
import java.security.KeyStore
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.ArrayDeque
import java.util.concurrent.atomic.AtomicInteger
import javax.net.ssl.KeyManagerFactory
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLServerSocket
import javax.net.ssl.SSLSocket
import javax.net.ssl.TrustManager
import javax.net.ssl.X509TrustManager

class AndroidTlsBridge {
    private val executor = Executors.newCachedThreadPool()
    private val nextConnectionId = AtomicInteger(1)
    private val connections = ConcurrentHashMap<Int, SSLSocket>()
    private var server: SSLServerSocket? = null
    private var pendingAccept: MethodChannel.Result? = null
    private val acceptedConnections = ArrayDeque<Map<String, Any>>()

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
                result.success(acceptedConnections.removeFirst())
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
        while (!listener.isClosed) {
            try {
                val socket = listener.accept() as SSLSocket
                socket.useClientMode = false
                socket.startHandshake()
                val id = register(socket)
                val certificate = socket.session.peerCertificates.firstOrNull() as? X509Certificate
                val response = mapOf(
                    "connectionId" to id,
                    "peerCertificateBase64" to Base64.encodeToString(
                        certificate?.encoded ?: ByteArray(0),
                        Base64.NO_WRAP,
                    ),
                )
                val callback = synchronized(this) {
                    val current = pendingAccept
                    if (current != null) {
                        pendingAccept = null
                    } else {
                        acceptedConnections.addLast(response)
                    }
                    current
                }
                callback?.success(response)
            } catch (_: Throwable) {
                if (listener.isClosed) return
            }
        }
    }

    private fun connect(arguments: Map<*, *>?, result: MethodChannel.Result) {
        executor.execute {
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
                val socket = context.socketFactory.createSocket() as SSLSocket
                socket.useClientMode = true
                socket.connect(InetSocketAddress(host, port), 10_000)
                socket.startHandshake()
                val id = register(socket)
                val certificate = socket.session.peerCertificates.firstOrNull() as? X509Certificate
                result.success(
                    mapOf(
                        "connectionId" to id,
                        "peerCertificateBase64" to Base64.encodeToString(
                            certificate?.encoded ?: ByteArray(0),
                            Base64.NO_WRAP,
                        ),
                    ),
                )
            } catch (error: Throwable) {
                result.error("connect_failed", error.message, null)
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
        executor.execute {
            try {
                val buffer = ByteArray(16 * 1024)
                val count = socket.inputStream.read(buffer)
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
                result.error("read_failed", error.message, null)
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
        executor.execute {
            try {
                val bytes = Base64.decode(data, Base64.DEFAULT)
                socket.outputStream.write(bytes)
                socket.outputStream.flush()
                result.success(true)
            } catch (error: Throwable) {
                result.error("write_failed", error.message, null)
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
        synchronized(this) {
            pendingAccept?.error("server_stopped", "TLS server stopped", null)
            pendingAccept = null
            acceptedConnections.clear()
        }
        server?.close()
        server = null
        connections.values.forEach { socket -> runCatching { socket.close() } }
        connections.clear()
    }

    private fun register(socket: SSLSocket): Int {
        val id = nextConnectionId.getAndIncrement()
        connections[id] = socket
        return id
    }

    private fun buildContext(certificatePem: String, privateKeyPem: String): SSLContext {
        val certificate = parseCertificate(certificatePem)
        val keyBytes = decodePem(privateKeyPem, "PRIVATE KEY")
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
}
