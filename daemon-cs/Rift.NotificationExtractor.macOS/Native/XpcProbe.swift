import Foundation

private let maximumResponseBytes = 1024 * 1024
private let timeout = DispatchTimeInterval.seconds(10)

private final class ProbeState: @unchecked Sendable {
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

@main
private struct XpcProbeMain {
    static func main() {
        let request = FileHandle.standardInput.readDataToEndOfFile()
        guard !request.isEmpty else {
            fputs("request required on stdin\n", stderr)
            exit(2)
        }

        let connection = NSXPCConnection(machServiceName: riftNotificationExtractorMachService)
        connection.remoteObjectInterface = NSXPCInterface(with: RiftNotificationExtractorXpcProtocol.self)
        connection.setCodeSigningRequirement("identifier \"com.rift.notification-extractor\" and certificate leaf[subject.CN] = \"Rift Development Code Signing\"")

        let completed = DispatchSemaphore(value: 0)
        let state = ProbeState()
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
            fputs("unable to create extractor proxy\n", stderr)
            exit(3)
        }

        proxy.request(request) { response in
            if state.complete(response: response) {
                completed.signal()
            }
        }

        if completed.wait(timeout: .now() + timeout) == .timedOut {
            connection.invalidate()
            fputs("extractor request timed out\n", stderr)
            exit(4)
        }

        let (response, failed) = state.result()
        connection.invalidate()
        guard !failed, let response else {
            fputs("extractor connection failed\n", stderr)
            exit(5)
        }
        guard response.count <= maximumResponseBytes else {
            fputs("extractor response exceeded 1 MiB\n", stderr)
            exit(6)
        }
        FileHandle.standardOutput.write(response)
    }
}
