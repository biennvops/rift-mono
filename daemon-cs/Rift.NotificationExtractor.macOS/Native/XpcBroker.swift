import Darwin
import Foundation

private let maximumRequestBytes = 64 * 1024
private let maximumResponseBytes = 1024 * 1024
private let maximumErrorBytes = 1024 * 1024
private let workerTimeout = DispatchTimeInterval.seconds(10)
private let readChunkBytes = 16 * 1024
private let maximumNotificationActionFieldCharacters = 512
private let nativeNotificationActionOperations = [
    "getNotificationActionBackendStatus",
    "getNotificationActionCapabilities",
    "dismissNotification"
]

private enum WorkerStream {
    case standardOutput
    case standardError
}

private final class WorkerOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var standardOutput = Data()
    private var standardError = Data()
    private var exceededLimit: WorkerStream?

    func append(_ data: Data, from stream: WorkerStream) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard exceededLimit == nil else { return false }
        let currentCount = stream == .standardOutput ? standardOutput.count : standardError.count
        let limit = stream == .standardOutput ? maximumResponseBytes : maximumErrorBytes
        guard data.count <= limit - currentCount else {
            exceededLimit = stream
            return false
        }

        switch stream {
        case .standardOutput:
            standardOutput.append(data)
        case .standardError:
            standardError.append(data)
        }
        return true
    }

    func result() -> (Data, WorkerStream?) {
        lock.lock()
        defer { lock.unlock() }
        return (standardOutput, exceededLimit)
    }
}

private final class ExtractorService: NSObject, RiftNotificationExtractorXpcProtocol {
    private let notificationActionBackend = makeMacOSNotificationActionBackend()

    func request(_ request: Data, withReply reply: @escaping (Data) -> Void) {
        guard request.count <= maximumRequestBytes else {
            reply(errorResponse(for: request, code: "requestTooLarge", message: "Extractor requests must not exceed 64 KiB."))
            return
        }

        if let response = handleNotificationActionRequest(request) {
            reply(response)
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            reply(self.runWorker(request: request))
        }
    }

    private func handleNotificationActionRequest(_ request: Data) -> Data? {
        guard
            let object = try? JSONSerialization.jsonObject(with: request) as? [String: Any],
            let operation = object["operation"] as? String,
            nativeNotificationActionOperations.contains(operation)
        else {
            return nil
        }

        switch operation {
        case "getNotificationActionBackendStatus":
            return successResponse(
                for: request,
                result: notificationActionBackend.status().jsonObject)
        case "getNotificationActionCapabilities":
            guard
                let notificationId = boundedActionField("notificationId", in: object),
                let packageName = boundedActionField("packageName", in: object)
            else {
                return errorResponse(
                    for: request,
                    code: "invalidRequest",
                    message: "notificationId and packageName must be non-empty strings no longer than 512 characters.")
            }
            return successResponse(
                for: request,
                result: notificationActionBackend.capabilities(
                    notificationId: notificationId,
                    packageName: packageName).jsonObject)
        case "dismissNotification":
            guard
                let notificationId = boundedActionField("notificationId", in: object),
                let packageName = boundedActionField("packageName", in: object)
            else {
                return errorResponse(
                    for: request,
                    code: "invalidRequest",
                    message: "notificationId and packageName must be non-empty strings no longer than 512 characters.")
            }
            return successResponse(
                for: request,
                result: notificationActionBackend.dismiss(
                    notificationId: notificationId,
                    packageName: packageName).jsonObject)
        default:
            return nil
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

        let output = WorkerOutput()
        let io = DispatchGroup()
        let stateChanged = DispatchSemaphore(value: 0)
        let deadline = DispatchTime.now() + workerTimeout
        process.terminationHandler = { _ in stateChanged.signal() }

        do {
            try process.run()
        } catch {
            closePipes(inputPipe, outputPipe, errorPipe)
            return errorResponse(for: request, code: "workerLaunchFailed", message: "The notification extractor worker could not be started.")
        }
        try? inputPipe.fileHandleForReading.close()
        try? outputPipe.fileHandleForWriting.close()
        try? errorPipe.fileHandleForWriting.close()

        io.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            read(outputPipe.fileHandleForReading, into: output, stream: .standardOutput, stateChanged: stateChanged)
            io.leave()
        }
        io.enter()
        DispatchQueue.global(qos: .utility).async {
            read(errorPipe.fileHandleForReading, into: output, stream: .standardError, stateChanged: stateChanged)
            io.leave()
        }
        io.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            var input = request
            input.append(0x0a)
            try? inputPipe.fileHandleForWriting.write(contentsOf: input)
            try? inputPipe.fileHandleForWriting.close()
            io.leave()
        }
        io.notify(queue: .global(qos: .userInitiated)) {
            stateChanged.signal()
        }

        while true {
            let (_, exceededLimit) = output.result()
            if let exceededLimit {
                stopWorker(process, inputPipe, outputPipe, errorPipe)
                io.wait()
                if exceededLimit == .standardOutput {
                    return errorResponse(for: request, code: "responseTooLarge", message: "The notification extractor response exceeded 1 MiB.")
                }
                return errorResponse(for: request, code: "workerFailed", message: "The notification extractor worker produced too much error output.")
            }

            if !process.isRunning, io.wait(timeout: .now()) == .success {
                break
            }
            if stateChanged.wait(timeout: deadline) == .timedOut {
                stopWorker(process, inputPipe, outputPipe, errorPipe)
                io.wait()
                return errorResponse(for: request, code: "workerTimeout", message: "The notification extractor worker timed out.")
            }
        }

        let (response, _) = output.result()
        guard process.terminationStatus == 0 else {
            return errorResponse(for: request, code: "workerFailed", message: "The notification extractor worker failed.")
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

private func read(
    _ handle: FileHandle,
    into output: WorkerOutput,
    stream: WorkerStream,
    stateChanged: DispatchSemaphore
) {
    while let data = try? handle.read(upToCount: readChunkBytes), !data.isEmpty {
        guard output.append(data, from: stream) else {
            stateChanged.signal()
            return
        }
    }
}

private func closePipes(_ inputPipe: Pipe, _ outputPipe: Pipe, _ errorPipe: Pipe) {
    try? inputPipe.fileHandleForReading.close()
    try? inputPipe.fileHandleForWriting.close()
    try? outputPipe.fileHandleForReading.close()
    try? outputPipe.fileHandleForWriting.close()
    try? errorPipe.fileHandleForReading.close()
    try? errorPipe.fileHandleForWriting.close()
}

private func stopWorker(_ process: Process, _ inputPipe: Pipe, _ outputPipe: Pipe, _ errorPipe: Pipe) {
    if process.isRunning {
        kill(process.processIdentifier, SIGKILL)
    }
    closePipes(inputPipe, outputPipe, errorPipe)
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

private func boundedActionField(_ name: String, in object: [String: Any]) -> String? {
    guard
        let value = object[name] as? String,
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        value.count <= maximumNotificationActionFieldCharacters
    else {
        return nil
    }
    return value
}

private func successResponse(for request: Data, result: [String: Any]) -> Data {
    let response: [String: Any] = [
        "id": requestId(from: request),
        "ok": true,
        "result": result
    ]
    guard
        let data = try? JSONSerialization.data(withJSONObject: response),
        data.count <= maximumResponseBytes
    else {
        return errorResponse(
            for: request,
            code: "invalidResponse",
            message: "The native notification action backend returned an invalid response.")
    }
    return data
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
        guard let allowedClientRequirement = riftPeerCodeSigningRequirement(identifier: "com.rift.daemon") else {
            fputs("Unable to determine daemon signing requirement.\n", stderr)
            exit(1)
        }

        let listener = NSXPCListener(machServiceName: riftNotificationExtractorMachService)
        listener.setConnectionCodeSigningRequirement(allowedClientRequirement)
        let delegate = ListenerDelegate()
        listener.delegate = delegate
        listener.activate()
        RunLoop.main.run()
    }
}
