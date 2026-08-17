import Foundation

let maximumExtractorResponseBytes = 1024 * 1024

private let maximumNotificationActionFieldCharacters = 512
private let nativeNotificationActionOperations: Set<String> = [
    "getNotificationActionBackendStatus",
    "getNotificationActionCapabilities",
    "dismissNotification"
]

struct NativeNotificationActionRequestHandler {
    private let backend: any MacOSNotificationActionBackend

    init(backend: any MacOSNotificationActionBackend) {
        self.backend = backend
    }

    func handle(_ request: Data) -> Data? {
        guard
            let object = try? JSONSerialization.jsonObject(with: request) as? [String: Any],
            let operation = object["operation"] as? String,
            nativeNotificationActionOperations.contains(operation)
        else {
            return nil
        }

        switch operation {
        case "getNotificationActionBackendStatus":
            return successResponse(for: request, result: backend.status().jsonObject)
        case "getNotificationActionCapabilities":
            guard
                let notificationId = boundedActionField("notificationId", in: object),
                let packageName = boundedActionField("packageName", in: object)
            else {
                return invalidActionRequest(for: request)
            }
            return successResponse(
                for: request,
                result: backend.capabilities(
                    notificationId: notificationId,
                    packageName: packageName).jsonObject)
        case "dismissNotification":
            guard
                let notificationId = boundedActionField("notificationId", in: object),
                let packageName = boundedActionField("packageName", in: object)
            else {
                return invalidActionRequest(for: request)
            }
            return successResponse(
                for: request,
                result: backend.dismiss(
                    notificationId: notificationId,
                    packageName: packageName).jsonObject)
        default:
            return nil
        }
    }
}

private func invalidActionRequest(for request: Data) -> Data {
    errorResponse(
        for: request,
        code: "invalidRequest",
        message: "notificationId and packageName must be non-empty strings no longer than 512 characters.")
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

private func requestId(from request: Data) -> String {
    guard
        let object = try? JSONSerialization.jsonObject(with: request) as? [String: Any],
        let requestId = object["id"] as? String
    else {
        return ""
    }
    return requestId
}

private func successResponse(for request: Data, result: [String: Any]) -> Data {
    let response: [String: Any] = [
        "id": requestId(from: request),
        "ok": true,
        "result": result
    ]
    guard
        let data = try? JSONSerialization.data(withJSONObject: response),
        data.count <= maximumExtractorResponseBytes
    else {
        return errorResponse(
            for: request,
            code: "invalidResponse",
            message: "The native notification action backend returned an invalid response.")
    }
    return data
}

func errorResponse(for request: Data, code: String, message: String) -> Data {
    let response: [String: Any] = [
        "id": requestId(from: request),
        "ok": false,
        "error": ["code": code, "message": message]
    ]
    return (try? JSONSerialization.data(withJSONObject: response)) ?? Data()
}
