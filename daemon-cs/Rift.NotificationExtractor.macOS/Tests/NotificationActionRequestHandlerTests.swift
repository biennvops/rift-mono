import Foundation

private enum TestFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case let .failed(message):
            return message
        }
    }
}

private func require(
    _ condition: @autoclosure () -> Bool,
    _ message: String
) throws {
    guard condition() else {
        throw TestFailure.failed(message)
    }
}

private func jsonData(_ object: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: object)
}

private func jsonObject(_ data: Data) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw TestFailure.failed("response was not a JSON object")
    }
    return object
}

private func errorCode(_ response: [String: Any]) -> String? {
    (response["error"] as? [String: Any])?["code"] as? String
}

private final class FakeBackend: MacOSNotificationActionBackend {
    var capabilityCalls: [(String, String)] = []
    var dismissCalls: [(String, String)] = []

    func status() -> MacOSNotificationActionBackendStatus {
        MacOSNotificationActionBackendStatus(
            backend: "fake",
            available: true,
            canEnumerate: true,
            canDismiss: true,
            reason: nil)
    }

    func capabilities(
        notificationId: String,
        packageName: String
    ) -> MacOSNotificationActionCapabilities {
        capabilityCalls.append((notificationId, packageName))
        return MacOSNotificationActionCapabilities(
            backend: "fake",
            canDismiss: true,
            canOpen: false,
            reason: nil)
    }

    func dismiss(
        notificationId: String,
        packageName: String
    ) -> MacOSNotificationDismissResult {
        dismissCalls.append((notificationId, packageName))
        return MacOSNotificationDismissResult(
            backend: "fake",
            success: true,
            reason: "verified")
    }
}

private func testCompiledBackend() throws {
    let status = makeMacOSNotificationActionBackend().status()
#if RIFT_PRIVATE_API && RIFT_PRIVATE_NOTIFICATION_ACTIONS
    try require(status.backend == "private", "private flavor did not select the private backend")
    try require(!status.available, "unqualified private backend became available")
    try require(!status.canEnumerate, "unqualified private backend can enumerate")
    try require(!status.canDismiss, "unqualified private backend can dismiss")
    try require(status.reason != nil, "private backend did not report its unavailable reason")
#elseif RIFT_ACCESSIBILITY_NOTIFICATION_ACTIONS
    try require(status.backend == "accessibility", "Accessibility flavor did not select its backend")
#else
    try require(status.backend == "none", "normal flavor selected an action backend")
    try require(status.reason == "notCompiled", "normal flavor did not report notCompiled")
    try require(!status.available, "normal flavor became available")
    try require(!status.canEnumerate, "normal flavor can enumerate")
    try require(!status.canDismiss, "normal flavor can dismiss")
#endif
}

private func testRequestRouting() throws {
    let backend = FakeBackend()
    let handler = NativeNotificationActionRequestHandler(backend: backend)

    let statusRequest = try jsonData([
        "id": "status-1",
        "operation": "getNotificationActionBackendStatus"
    ])
    guard let statusData = handler.handle(statusRequest) else {
        throw TestFailure.failed("status request was forwarded")
    }
    let status = try jsonObject(statusData)
    try require(status["id"] as? String == "status-1", "status response did not preserve its ID")
    try require(status["ok"] as? Bool == true, "status request failed")
    let statusResult = status["result"] as? [String: Any]
    try require(statusResult?["backend"] as? String == "fake", "status used the wrong backend")

    let capabilitiesRequest = try jsonData([
        "id": "capabilities-1",
        "operation": "getNotificationActionCapabilities",
        "notificationId": "notification-1",
        "packageName": "com.example.source"
    ])
    guard let capabilitiesData = handler.handle(capabilitiesRequest) else {
        throw TestFailure.failed("capabilities request was forwarded")
    }
    let capabilities = try jsonObject(capabilitiesData)
    try require(capabilities["ok"] as? Bool == true, "valid capabilities request failed")
    try require(backend.capabilityCalls.count == 1, "capabilities backend call count was incorrect")
    try require(backend.capabilityCalls[0].0 == "notification-1", "notification ID changed")
    try require(backend.capabilityCalls[0].1 == "com.example.source", "package name changed")

    let maximumField = String(repeating: "a", count: 512)
    let maximumRequest = try jsonData([
        "id": "maximum-1",
        "operation": "getNotificationActionCapabilities",
        "notificationId": maximumField,
        "packageName": maximumField
    ])
    try require(handler.handle(maximumRequest) != nil, "512-character field was rejected")
    try require(backend.capabilityCalls.count == 2, "maximum request did not reach backend")

    let dismissRequest = try jsonData([
        "id": "dismiss-1",
        "operation": "dismissNotification",
        "notificationId": "notification-2",
        "packageName": "com.example.source"
    ])
    guard let dismissData = handler.handle(dismissRequest) else {
        throw TestFailure.failed("dismiss request was forwarded")
    }
    let dismiss = try jsonObject(dismissData)
    try require(dismiss["ok"] as? Bool == true, "valid dismiss request failed")
    let dismissResult = dismiss["result"] as? [String: Any]
    try require(dismissResult?["success"] as? Bool == true, "backend dismiss result was lost")
    try require(backend.dismissCalls.count == 1, "dismiss backend call count was incorrect")

    let invalidRequests: [[String: Any]] = [
        [
            "id": "empty-notification",
            "operation": "getNotificationActionCapabilities",
            "notificationId": "",
            "packageName": "com.example.source"
        ],
        [
            "id": "blank-package",
            "operation": "getNotificationActionCapabilities",
            "notificationId": "notification-1",
            "packageName": " \n "
        ],
        [
            "id": "long-notification",
            "operation": "dismissNotification",
            "notificationId": String(repeating: "a", count: 513),
            "packageName": "com.example.source"
        ],
        [
            "id": "long-package",
            "operation": "dismissNotification",
            "notificationId": "notification-1",
            "packageName": String(repeating: "a", count: 513)
        ],
        [
            "id": "non-string-notification",
            "operation": "dismissNotification",
            "notificationId": 1,
            "packageName": "com.example.source"
        ],
        [
            "id": "missing-package",
            "operation": "dismissNotification",
            "notificationId": "notification-1"
        ]
    ]

    for invalidRequest in invalidRequests {
        let request = try jsonData(invalidRequest)
        guard let responseData = handler.handle(request) else {
            throw TestFailure.failed("known invalid native request was forwarded")
        }
        let response = try jsonObject(responseData)
        try require(response["ok"] as? Bool == false, "invalid request succeeded")
        try require(errorCode(response) == "invalidRequest", "invalid request used the wrong error")
        try require(response["id"] as? String == invalidRequest["id"] as? String, "invalid response lost its ID")
    }
    try require(backend.dismissCalls.count == 1, "invalid dismiss request reached backend")
    try require(backend.capabilityCalls.count == 2, "invalid capabilities request reached backend")

    let forwardedObjects: [Any] = [
        ["id": "extract-1", "operation": "getStatus"],
        ["id": "unknown-1", "operation": "unknownOperation"],
        ["id": "missing-operation"],
        ["not", "an", "object"]
    ]
    for object in forwardedObjects {
        let request = try jsonData(object)
        try require(handler.handle(request) == nil, "non-native request was intercepted")
    }
    try require(handler.handle(Data("not json".utf8)) == nil, "malformed request was intercepted")
}

#if RIFT_ACCESSIBILITY_NOTIFICATION_ACTIONS

private enum FakeAccessibilityError: Error {
    case failed
}

private final class FakeAccessibilityRuntime: AccessibilityNotificationRuntime {
    var trusted = true
    var centerAvailable = true
    var snapshots: [[AccessibilityNotificationCandidate]] = []
    var candidatesError = false
    var performResult = true
    var performError = false
    private(set) var performedActions: [String] = []
    private var snapshotIndex = 0

    func isTrusted() -> Bool {
        trusted
    }

    func notificationCenterAvailable() -> Bool {
        centerAvailable
    }

    func candidates() throws -> [AccessibilityNotificationCandidate] {
        if candidatesError {
            throw FakeAccessibilityError.failed
        }
        guard !snapshots.isEmpty else {
            return []
        }
        let result = snapshots[min(snapshotIndex, snapshots.count - 1)]
        snapshotIndex += 1
        return result
    }

    func perform(
        action: String,
        on candidate: AccessibilityNotificationCandidate
    ) throws -> Bool {
        if performError {
            throw FakeAccessibilityError.failed
        }
        performedActions.append(action)
        return performResult
    }
}

private let accessibilityTargetId = "11111111-1111-4111-8111-111111111111"
private let accessibilitySiblingId = "22222222-2222-4222-8222-222222222222"
private let accessibilityCloseAction = "Name:Close\nTarget:0x0\nSelector:(null)"
private let accessibilityClearAllAction = "Name:Clear All\nTarget:0x0\nSelector:(null)"

private func accessibilityCandidate(
    identifier: String = accessibilityTargetId,
    subrole: String = "AXNotificationCenterBanner",
    actions: [String] = [accessibilityCloseAction]
) -> AccessibilityNotificationCandidate {
    AccessibilityNotificationCandidate(
        identifier: identifier,
        subrole: subrole,
        actions: actions)
}

private func accessibilityBackend(
    _ runtime: FakeAccessibilityRuntime,
    verificationAttempts: Int = 1
) -> AccessibilityMacOSNotificationActionBackend {
    AccessibilityMacOSNotificationActionBackend(
        runtime: runtime,
        verificationAttempts: verificationAttempts,
        verificationPause: { _ in })
}

private func testAccessibilityBackend() throws {
    do {
        let runtime = FakeAccessibilityRuntime()
        runtime.trusted = false
        let status = accessibilityBackend(runtime).status()
        try require(!status.available, "untrusted Accessibility backend became available")
        try require(status.reason == "accessibilityNotTrusted", "untrusted status reason was wrong")
    }

    do {
        let runtime = FakeAccessibilityRuntime()
        runtime.centerAvailable = false
        let status = accessibilityBackend(runtime).status()
        try require(!status.available, "backend without Notification Center became available")
        try require(status.reason == "notificationCenterUnavailable", "missing process reason was wrong")
    }

    do {
        let runtime = FakeAccessibilityRuntime()
        runtime.snapshots = [[]]
        let capabilities = accessibilityBackend(runtime).capabilities(
            notificationId: accessibilityTargetId,
            packageName: "com.example.source")
        try require(!capabilities.canDismiss, "zero-result lookup became dismissible")
        try require(capabilities.reason == "exactIdentityUnavailable", "zero-result reason was wrong")
    }

    do {
        let runtime = FakeAccessibilityRuntime()
        runtime.snapshots = [[accessibilityCandidate(), accessibilityCandidate()]]
        let capabilities = accessibilityBackend(runtime).capabilities(
            notificationId: accessibilityTargetId,
            packageName: "com.example.source")
        try require(!capabilities.canDismiss, "ambiguous lookup became dismissible")
        try require(capabilities.reason == "accessibilityIdentityAmbiguous", "ambiguous reason was wrong")
    }

    do {
        let runtime = FakeAccessibilityRuntime()
        runtime.snapshots = [[accessibilityCandidate(actions: ["AXPress", accessibilityClearAllAction])]]
        let capabilities = accessibilityBackend(runtime).capabilities(
            notificationId: accessibilityTargetId,
            packageName: "com.example.source")
        try require(!capabilities.canDismiss, "Clear All candidate became dismissible")
        try require(
            capabilities.reason == "accessibilityNoIndividualCloseAction",
            "Clear All reason was wrong")
    }

    do {
        let runtime = FakeAccessibilityRuntime()
        runtime.snapshots = [[accessibilityCandidate(actions: ["AXPress", accessibilityCloseAction])]]
        let capabilities = accessibilityBackend(runtime).capabilities(
            notificationId: accessibilityTargetId.lowercased(),
            packageName: "com.example.source")
        try require(capabilities.canDismiss, "exact UUID with Close was not dismissible")
        try require(!capabilities.canOpen, "Accessibility backend advertised open")
    }

    do {
        let runtime = FakeAccessibilityRuntime()
        let target = accessibilityCandidate(actions: ["AXPress", accessibilityCloseAction])
        let sibling = accessibilityCandidate(identifier: accessibilitySiblingId)
        let newNotification = accessibilityCandidate(
            identifier: "33333333-3333-4333-8333-333333333333")
        runtime.snapshots = [[target, sibling], [sibling, newNotification]]
        let result = accessibilityBackend(runtime).dismiss(
            notificationId: accessibilityTargetId,
            packageName: "com.example.source")
        try require(result.success, "verified exact dismissal failed")
        try require(result.reason == "verified", "verified dismissal reason was wrong")
        try require(runtime.performedActions == [accessibilityCloseAction], "wrong AX action ran")
    }

    do {
        let runtime = FakeAccessibilityRuntime()
        let target = accessibilityCandidate()
        let sibling = accessibilityCandidate(identifier: accessibilitySiblingId)
        runtime.snapshots = [[target, sibling], [target, sibling]]
        let result = accessibilityBackend(runtime).dismiss(
            notificationId: accessibilityTargetId,
            packageName: "com.example.source")
        try require(!result.success, "verification timeout succeeded")
        try require(result.reason == "verificationFailed", "verification timeout reason was wrong")
    }

    do {
        let runtime = FakeAccessibilityRuntime()
        let target = accessibilityCandidate()
        let sibling = accessibilityCandidate(identifier: accessibilitySiblingId)
        runtime.snapshots = [[target, sibling], []]
        let result = accessibilityBackend(runtime).dismiss(
            notificationId: accessibilityTargetId,
            packageName: "com.example.source")
        try require(!result.success, "sibling disappearance was accepted")
        try require(result.reason == "verificationFailed", "sibling failure reason was wrong")
    }

    do {
        let runtime = FakeAccessibilityRuntime()
        runtime.snapshots = [[accessibilityCandidate()]]
        runtime.performResult = false
        let result = accessibilityBackend(runtime).dismiss(
            notificationId: accessibilityTargetId,
            packageName: "com.example.source")
        try require(!result.success, "failed AX action succeeded")
        try require(result.reason == "accessibilityActionFailed", "failed action reason was wrong")
    }

    do {
        let runtime = FakeAccessibilityRuntime()
        runtime.snapshots = [[]]
        let result = accessibilityBackend(runtime).dismiss(
            notificationId: accessibilityTargetId,
            packageName: "com.example.source")
        try require(!result.success, "already absent target triggered success")
        try require(result.reason == "exactIdentityUnavailable", "stale target reason was wrong")
        try require(runtime.performedActions.isEmpty, "stale target invoked an action")
    }

    do {
        let runtime = FakeAccessibilityRuntime()
        runtime.candidatesError = true
        let result = accessibilityBackend(runtime).dismiss(
            notificationId: accessibilityTargetId,
            packageName: "com.example.source")
        try require(!result.success, "AX enumeration exception succeeded")
        try require(result.reason == "accessibilityUnavailable", "enumeration exception reason was wrong")
    }
}

#endif

@main
private struct NotificationActionRequestHandlerTests {
    static func main() throws {
        try testCompiledBackend()
        try testRequestRouting()
#if RIFT_ACCESSIBILITY_NOTIFICATION_ACTIONS
        try testAccessibilityBackend()
#endif
        print("notification action request tests passed")
    }
}
