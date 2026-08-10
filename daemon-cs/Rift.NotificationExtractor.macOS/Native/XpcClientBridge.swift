import Darwin
import Foundation

private let maximumResponseBytes = 1024 * 1024

private final class ClientState: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private var response: Data?
    private var failed = false

    func complete(response: Data? = nil, failed: Bool = false) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !completed else { return false }
        completed = true
        self.response = response
        self.failed = failed
        return true
    }

    func result() -> (Data?, Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (response, failed)
    }
}

@_cdecl("rift_notification_xpc_send")
public func riftNotificationXpcSend(
    _ requestBytes: UnsafePointer<UInt8>?,
    _ requestLength: Int32,
    _ timeoutMilliseconds: Int32,
    _ responseBytes: UnsafeMutablePointer<UnsafeMutableRawPointer?>?,
    _ responseLength: UnsafeMutablePointer<Int32>?
) -> Int32 {
    guard
        let requestBytes,
        requestLength > 0,
        timeoutMilliseconds > 0,
        let responseBytes,
        let responseLength
    else {
        return 1
    }

    responseBytes.pointee = nil
    responseLength.pointee = 0
    guard let extractorRequirement = riftPeerCodeSigningRequirement(identifier: "com.rift.notification-extractor") else {
        return 2
    }

    let request = Data(bytes: requestBytes, count: Int(requestLength))
    let connection = NSXPCConnection(machServiceName: riftNotificationExtractorMachService)
    connection.remoteObjectInterface = NSXPCInterface(with: RiftNotificationExtractorXpcProtocol.self)
    connection.setCodeSigningRequirement(extractorRequirement)

    let completed = DispatchSemaphore(value: 0)
    let state = ClientState()
    let fail: @Sendable () -> Void = {
        if state.complete(failed: true) {
            completed.signal()
        }
    }
    connection.interruptionHandler = fail
    connection.invalidationHandler = fail
    connection.activate()

    let proxy = connection.remoteObjectProxyWithErrorHandler { _ in fail() }
        as? RiftNotificationExtractorXpcProtocol
    guard let proxy else {
        connection.invalidate()
        return 2
    }

    proxy.request(request) { response in
        if state.complete(response: response) {
            completed.signal()
        }
    }

    let timeout = DispatchTime.now() + .milliseconds(Int(timeoutMilliseconds))
    guard completed.wait(timeout: timeout) == .success else {
        connection.invalidate()
        return 3
    }

    let (response, failed) = state.result()
    connection.invalidate()
    guard !failed, let response else {
        return 2
    }
    guard response.count <= maximumResponseBytes else {
        return 4
    }
    guard let allocated = malloc(response.count) else {
        return 5
    }
    response.copyBytes(to: allocated.assumingMemoryBound(to: UInt8.self), count: response.count)
    responseBytes.pointee = allocated
    responseLength.pointee = Int32(response.count)
    return 0
}

@_cdecl("rift_notification_xpc_free")
public func riftNotificationXpcFree(_ pointer: UnsafeMutableRawPointer?) {
    free(pointer)
}
