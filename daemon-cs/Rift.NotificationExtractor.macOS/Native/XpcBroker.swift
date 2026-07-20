import Foundation

private let maximumRequestBytes = 64 * 1024
private let maximumResponseBytes = 1024 * 1024
private let workerTimeout = DispatchTimeInterval.seconds(10)

private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Data()

    func set(_ data: Data) {
        lock.lock()
        value = data
        lock.unlock()
    }

    func get() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private final class ExtractorService: NSObject, RiftNotificationExtractorXpcProtocol {
    func request(_ request: Data, withReply reply: @escaping (Data) -> Void) {
        guard request.count <= maximumRequestBytes else {
            reply(errorResponse(for: request, code: "requestTooLarge", message: "Extractor requests must not exceed 64 KiB."))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            reply(self.runWorker(request: request))
        }
    }

    private func runWorker(request: Data) -> Data {
        guard let workerPath = workerPath(), FileManager.default.isExecutableFile(atPath: workerPath) else {
            return errorResponse(for: request, code: "workerNotFound", message: "The notification extractor worker is unavailable.")
        }

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: workerPath)
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let output = DataBox()
        let errorOutput = DataBox()
        let readers = DispatchGroup()
        let terminated = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in terminated.signal() }

        do {
            try process.run()
            try? inputPipe.fileHandleForReading.close()
            try? outputPipe.fileHandleForWriting.close()
            try? errorPipe.fileHandleForWriting.close()

            readers.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                output.set(outputPipe.fileHandleForReading.readDataToEndOfFile())
                readers.leave()
            }
            readers.enter()
            DispatchQueue.global(qos: .utility).async {
                errorOutput.set(errorPipe.fileHandleForReading.readDataToEndOfFile())
                readers.leave()
            }

            inputPipe.fileHandleForWriting.write(request)
            inputPipe.fileHandleForWriting.write(Data([0x0a]))
            try inputPipe.fileHandleForWriting.close()
        } catch {
            try? inputPipe.fileHandleForReading.close()
            try? inputPipe.fileHandleForWriting.close()
            try? outputPipe.fileHandleForReading.close()
            try? outputPipe.fileHandleForWriting.close()
            try? errorPipe.fileHandleForReading.close()
            try? errorPipe.fileHandleForWriting.close()
            return errorResponse(for: request, code: "workerLaunchFailed", message: "The notification extractor worker could not be started.")
        }

        if terminated.wait(timeout: .now() + workerTimeout) == .timedOut {
            process.terminate()
            _ = terminated.wait(timeout: .now() + .seconds(2))
            readers.wait()
            return errorResponse(for: request, code: "workerTimeout", message: "The notification extractor worker timed out.")
        }

        readers.wait()
        let response = output.get()
        guard process.terminationStatus == 0 else {
            _ = errorOutput.get()
            return errorResponse(for: request, code: "workerFailed", message: "The notification extractor worker failed.")
        }
        guard response.count <= maximumResponseBytes else {
            return errorResponse(for: request, code: "responseTooLarge", message: "The notification extractor response exceeded 1 MiB.")
        }
        guard !response.isEmpty else {
            return errorResponse(for: request, code: "invalidResponse", message: "The notification extractor worker returned an empty response.")
        }
        return response
    }

    private func workerPath() -> String? {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent("rift-notification-extractor-worker")
            .path
    }
}

private final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let service = ExtractorService()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: RiftNotificationExtractorXpcProtocol.self)
        connection.exportedObject = service
        connection.activate()
        return true
    }
}

private func requestId(from request: Data) -> String {
    guard
        let object = try? JSONSerialization.jsonObject(with: request) as? [String: Any],
        let requestId = object["id"] as? String
    else {
        return ""
    }
    return requestId
}

private func errorResponse(for request: Data, code: String, message: String) -> Data {
    let response: [String: Any] = [
        "id": requestId(from: request),
        "ok": false,
        "error": ["code": code, "message": message]
    ]
    return (try? JSONSerialization.data(withJSONObject: response)) ?? Data()
}

@main
private struct XpcBrokerMain {
    static func main() {
        let listener = NSXPCListener(machServiceName: riftNotificationExtractorMachService)
        let allowedClientRequirement = Bundle.main.object(forInfoDictionaryKey: "RiftAllowedClientRequirement") as? String
            ?? "identifier \"com.rift.daemon\""
        listener.setConnectionCodeSigningRequirement(allowedClientRequirement)
        let delegate = ListenerDelegate()
        listener.delegate = delegate
        listener.activate()
        RunLoop.main.run()
    }
}
