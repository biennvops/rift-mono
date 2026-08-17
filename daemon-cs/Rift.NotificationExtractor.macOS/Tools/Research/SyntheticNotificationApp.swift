import Foundation
import UserNotifications

private let timeout: TimeInterval = 15

private func waitForCompletion(
    _ start: (@escaping (Error?) -> Void) -> Void
) throws {
    let semaphore = DispatchSemaphore(value: 0)
    var result: Error?
    start { error in
        result = error
        semaphore.signal()
    }
    guard semaphore.wait(timeout: .now() + timeout) == .success else {
        throw NSError(domain: "RiftNotificationResearch", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Notification operation timed out."
        ])
    }
    if let result {
        throw result
    }
}

private func requestAuthorization() throws {
    try waitForCompletion { completion in
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, error in
            if let error {
                completion(error)
            } else if !granted {
                completion(NSError(domain: "RiftNotificationResearch", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "Notification permission was denied."
                ]))
            } else {
                completion(nil)
            }
        }
    }
}

private func printAuthorizationStatus() {
    let semaphore = DispatchSemaphore(value: 0)
    UNUserNotificationCenter.current().getNotificationSettings { settings in
        let status: String
        switch settings.authorizationStatus {
        case .notDetermined:
            status = "notDetermined"
        case .denied:
            status = "denied"
        case .authorized:
            status = "authorized"
        case .provisional:
            status = "provisional"
        case .ephemeral:
            status = "ephemeral"
        @unknown default:
            status = "unknown"
        }
        print(status)
        semaphore.signal()
    }
    if semaphore.wait(timeout: .now() + timeout) != .success {
        fputs("status timed out\n", stderr)
    }
}

private func printDeliveredIdentifiers() {
    let semaphore = DispatchSemaphore(value: 0)
    UNUserNotificationCenter.current().getDeliveredNotifications { notifications in
        for identifier in notifications.map(\.request.identifier).sorted() {
            print(identifier)
        }
        semaphore.signal()
    }
    if semaphore.wait(timeout: .now() + timeout) != .success {
        fputs("delivered query timed out\n", stderr)
    }
}

private func post(identifier: String, title: String, body: String) throws {
    guard identifier.hasPrefix("RIFT-RESEARCH-") else {
        throw NSError(domain: "RiftNotificationResearch", code: 3, userInfo: [
            NSLocalizedDescriptionKey: "Synthetic identifiers must start with RIFT-RESEARCH-."
        ])
    }

    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    try waitForCompletion { completion in
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: identifier, content: content, trigger: nil),
            withCompletionHandler: completion)
    }
}

@main
private struct SyntheticNotificationAppMain {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let command = arguments.first else {
            throw NSError(domain: "RiftNotificationResearch", code: 64, userInfo: [
                NSLocalizedDescriptionKey: "usage: status | delivered | authorize | post IDENTIFIER TITLE BODY"
            ])
        }

        switch command {
        case "status":
            printAuthorizationStatus()
        case "delivered":
            printDeliveredIdentifiers()
        case "authorize":
            try requestAuthorization()
        case "post":
            guard arguments.count == 4 else {
                throw NSError(domain: "RiftNotificationResearch", code: 64, userInfo: [
                    NSLocalizedDescriptionKey: "post requires IDENTIFIER TITLE BODY."
                ])
            }
            try post(identifier: arguments[1], title: arguments[2], body: arguments[3])
        default:
            throw NSError(domain: "RiftNotificationResearch", code: 64, userInfo: [
                NSLocalizedDescriptionKey: "unknown command."
            ])
        }
    }
}
