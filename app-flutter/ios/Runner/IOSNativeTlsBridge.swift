import Foundation
import Network
import Security

final class IOSNativeTlsBridge {
  private struct Connection {
    let connection: NWConnection
    let peerCertificate: Data
    let remoteAddress: String
    let remotePort: Int
  }

  private var listener: NWListener?
  private var connections: [Int: Connection] = [:]
  private var nextConnectionId = 1
  private var pendingAccept: FlutterResult?
  private var accepted: [[String: Any]] = []
  private let queue = DispatchQueue(label: "dev.rift.native-tls")

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "startServer": startServer(call.arguments, result: result)
    case "accept": accept(result: result)
    case "connect": connect(call.arguments, result: result)
    case "read": read(call.arguments, result: result)
    case "write": write(call.arguments, result: result)
    case "close": close(call.arguments, result: result)
    case "stopServer": stopServer(result: result)
    default: result(FlutterMethodNotImplemented)
    }
  }

  func dispose() {
    stopServer(result: { _ in })
  }

  private func startServer(_ arguments: Any?, result: @escaping FlutterResult) {
    guard let args = arguments as? [String: Any],
          let certificatePem = args["certificatePem"] as? String,
          let privateKeyPem = args["privateKeyPem"] as? String,
          let identity = makeIdentity(certificatePem: certificatePem, privateKeyPem: privateKeyPem) else {
      NSLog("[Rift TLS] iOS native identity construction failed.")
      result(FlutterError(code: "invalid_arguments", message: "TLS identity is invalid.", details: nil))
      return
    }

    stopServer(result: { _ in })
    do {
      let options = NWProtocolTLS.Options()
      sec_protocol_options_set_local_identity(options.securityProtocolOptions, identity)
      sec_protocol_options_set_peer_authentication_required(options.securityProtocolOptions, true)
      sec_protocol_options_set_verify_block(options.securityProtocolOptions, { _, _, complete in
        complete(true)
      }, queue)
      let parameters = NWParameters(tls: options)
      parameters.allowLocalEndpointReuse = true
      let requestedPort = (args["port"] as? NSNumber)?.uint16Value ?? 0
      let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: requestedPort)!)
      listener.newConnectionHandler = { [weak self] connection in
        self?.prepare(connection)
      }
      listener.stateUpdateHandler = { state in
        if case .failed(let error) = state {
          NSLog("[Rift TLS] iOS listener failed: %@", error.localizedDescription)
          result(FlutterError(code: "start_server_failed", message: error.localizedDescription, details: nil))
        } else if case .ready = state {
          result(["port": listener.port?.rawValue ?? requestedPort])
        }
      }
      self.listener = listener
      listener.start(queue: queue)
    } catch {
      result(FlutterError(code: "start_server_failed", message: error.localizedDescription, details: nil))
    }
  }

  private func prepare(_ connection: NWConnection) {
    connection.stateUpdateHandler = { [weak self] state in
      guard case .ready = state, let self else { return }
      guard let metadata = connection.metadata(definition: NWProtocolTLS.definition) else { return }
      let certificate = self.peerCertificate(from: metadata) ?? Data()
      let id = self.register(connection, certificate: certificate)
      let endpoint = connection.currentPath?.remoteEndpoint
      let address: String
      let port: Int
      if case .hostPort(let host, let remotePort) = endpoint {
        address = host.debugDescription
        port = Int(remotePort.rawValue)
      } else {
        address = ""
        port = 0
      }
      let response: [String: Any] = [
        "connectionId": id,
        "peerCertificateBase64": certificate.base64EncodedString(),
        "remoteAddress": address,
        "remotePort": port,
      ]
      self.queue.sync {
        if let pending = self.pendingAccept {
          self.pendingAccept = nil
          pending(response)
        } else {
          self.accepted.append(response)
        }
      }
    }
    connection.start(queue: queue)
  }

  private func accept(result: @escaping FlutterResult) {
    queue.sync {
      if !accepted.isEmpty {
        result(accepted.removeFirst())
      } else if pendingAccept != nil {
        result(FlutterError(code: "accept_pending", message: "Accept already pending.", details: nil))
      } else {
        pendingAccept = result
      }
    }
  }

  private func connect(_ arguments: Any?, result: @escaping FlutterResult) {
    guard let args = arguments as? [String: Any],
          let host = args["host"] as? String,
          let port = (args["port"] as? NSNumber)?.uint16Value,
          let certificatePem = args["certificatePem"] as? String,
          let privateKeyPem = args["privateKeyPem"] as? String,
          let identity = makeIdentity(certificatePem: certificatePem, privateKeyPem: privateKeyPem) else {
      result(FlutterError(code: "invalid_arguments", message: "TLS connection arguments are invalid.", details: nil))
      return
    }
    let options = NWProtocolTLS.Options()
    sec_protocol_options_set_local_identity(options.securityProtocolOptions, identity)
    sec_protocol_options_set_peer_authentication_required(options.securityProtocolOptions, true)
    sec_protocol_options_set_verify_block(options.securityProtocolOptions, { _, _, complete in
      complete(true)
    }, queue)
    let parameters = NWParameters(tls: options)
    let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: parameters)
    connection.stateUpdateHandler = { [weak self] state in
      if case .failed(let error) = state {
        NSLog("[Rift TLS] iOS outbound connection failed: %@", error.localizedDescription)
        result(FlutterError(code: "connect_failed", message: error.localizedDescription, details: nil))
        return
      }
      guard case .ready = state, let self else { return }
      guard let metadata = connection.metadata(definition: NWProtocolTLS.definition) else {
        NSLog("[Rift TLS] iOS outbound connection had no TLS metadata.")
        result(FlutterError(code: "connect_failed", message: "TLS metadata unavailable.", details: nil))
        return
      }
      let certificate = self.peerCertificate(from: metadata) ?? Data()
      let id = self.register(connection, certificate: certificate)
      result([
        "connectionId": id,
        "peerCertificateBase64": certificate.base64EncodedString(),
        "remoteAddress": host,
        "remotePort": Int(port),
      ])
    }
    connection.stateUpdateHandler = connection.stateUpdateHandler
    connection.start(queue: queue)
  }

  private func read(_ arguments: Any?, result: @escaping FlutterResult) {
    guard let args = arguments as? [String: Any],
          let id = (args["connectionId"] as? NSNumber)?.intValue,
          let record = connections[id] else {
      result(FlutterError(code: "connection_not_found", message: "TLS connection not found.", details: nil))
      return
    }
    record.connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { data, _, isComplete, error in
      if let error {
        result(FlutterError(code: "read_failed", message: error.localizedDescription, details: nil))
      } else if isComplete && (data == nil || data?.isEmpty == true) {
        result(["eof": true])
      } else {
        result(["eof": false, "dataBase64": (data ?? Data()).base64EncodedString()])
      }
    }
  }

  private func write(_ arguments: Any?, result: @escaping FlutterResult) {
    guard let args = arguments as? [String: Any],
          let id = (args["connectionId"] as? NSNumber)?.intValue,
          let encoded = args["dataBase64"] as? String,
          let data = Data(base64Encoded: encoded),
          let record = connections[id] else {
      result(FlutterError(code: "invalid_write", message: "TLS write arguments are invalid.", details: nil))
      return
    }
    record.connection.send(content: data, completion: .contentProcessed { error in
      if let error {
        result(FlutterError(code: "write_failed", message: error.localizedDescription, details: nil))
      } else {
        result(true)
      }
    })
  }

  private func close(_ arguments: Any?, result: @escaping FlutterResult) {
    guard let args = arguments as? [String: Any],
          let id = (args["connectionId"] as? NSNumber)?.intValue else {
      result(FlutterError(code: "invalid_arguments", message: "connectionId is required.", details: nil))
      return
    }
    connections.removeValue(forKey: id)?.connection.cancel()
    result(true)
  }

  private func stopServer(result: @escaping FlutterResult) {
    listener?.cancel()
    listener = nil
    connections.values.forEach { $0.connection.cancel() }
    connections.removeAll()
    accepted.removeAll()
    pendingAccept?(FlutterError(code: "server_stopped", message: "TLS server stopped.", details: nil))
    pendingAccept = nil
    result(true)
  }

  private func register(_ connection: NWConnection, certificate: Data) -> Int {
    let id = nextConnectionId
    nextConnectionId += 1
    connections[id] = Connection(connection: connection, peerCertificate: certificate, remoteAddress: "", remotePort: 0)
    return id
  }

  private func peerCertificate(from metadata: NWProtocolMetadata) -> Data? {
    guard let tlsMetadata = metadata as? NWProtocolTLS.Metadata else {
      NSLog("[Rift TLS] iOS peer metadata was not TLS metadata.")
      return nil
    }
    var certificateData: Data?
    sec_protocol_metadata_access_peer_certificate_chain(tlsMetadata.securityProtocolMetadata) { certificate in
      certificateData = SecCertificateCopyData(sec_certificate_copy_ref(certificate).takeUnretainedValue()) as Data
    }
    return certificateData
  }

  private func makeIdentity(certificatePem: String, privateKeyPem: String) -> sec_identity_t? {
    guard let certificateData = pemData(certificatePem, label: "CERTIFICATE"),
          let certificate = SecCertificateCreateWithData(nil, certificateData as CFData),
          let sec1 = pemData(privateKeyPem, label: "EC PRIVATE KEY"),
          let scalar = ecPrivateScalar(from: sec1) else { return nil }
    let attributes: [CFString: Any] = [
      kSecAttrKeyType: kSecAttrKeyTypeEC,
      kSecAttrKeyClass: kSecAttrKeyClassPrivate,
      kSecAttrKeySizeInBits: 256,
    ]
    guard let key = SecKeyCreateWithData(scalar as NSData as CFData, attributes as CFDictionary, nil),
          let identity = SecIdentityCreate(nil, certificate, key) else { return nil }
    return sec_identity_create(identity)
  }

  private func pemData(_ pem: String, label: String) -> Data? {
    let body = pem
      .replacingOccurrences(of: "-----BEGIN \(label)-----", with: "")
      .replacingOccurrences(of: "-----END \(label)-----", with: "")
      .components(separatedBy: .whitespacesAndNewlines).joined()
    return Data(base64Encoded: body)
  }

  private func ecPrivateScalar(from der: Data) -> Data? {
    let bytes = [UInt8](der)
    guard bytes.count > 4, bytes[0] == 0x30 else { return nil }
    var index = 2
    guard bytes[index] == 0x02 else { return nil }
    index += 2
    guard bytes[index] == 0x01, bytes[index + 1] == 0x00 else { return nil }
    index += 2
    guard bytes[index] == 0x04 else { return nil }
    index += 1
    let length = Int(bytes[index])
    index += 1
    guard length == 32, index + length <= bytes.count else { return nil }
    return Data(bytes[index..<(index + length)])
  }
}
