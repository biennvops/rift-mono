import Foundation
import FlutterMacOS
import UserNotifications

final class PermissionsBridge {
  static let channelName = "rift.permissions"

  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    let instance = PermissionsBridge()
    channel.setMethodCallHandler(instance.handle)
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "notification.getStatus":
      getNotificationStatus(result: result)
    case "notification.request":
      requestNotification(result: result)
    case "notification.show":
      showNotification(args: call.arguments, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func getNotificationStatus(result: @escaping FlutterResult) {
    UNUserNotificationCenter.current().getNotificationSettings { settings in
      // 0 = notDetermined, 1 = denied, 2 = authorized
      let status: String
      switch settings.authorizationStatus {
      case .notDetermined:
        status = "notDetermined"
      case .denied:
        status = "denied"
      case .authorized, .provisional:
        status = "authorized"
      @unknown default:
        status = "unknown"
      }
      result(status)
    }
  }

  private func requestNotification(result: @escaping FlutterResult) {
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
      if let error = error {
        result(FlutterError(code: "notification_request_failed", message: error.localizedDescription, details: nil))
        return
      }
      result(granted)
    }
  }

  private func showNotification(args: Any?, result: @escaping FlutterResult) {
    let dict = args as? [String: Any]
    let title = dict?["title"] as? String ?? "Rift"
    let body = dict?["body"] as? String ?? ""

    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.sound = .default

    let request = UNNotificationRequest(
      identifier: UUID().uuidString,
      content: content,
      trigger: nil
    )

    UNUserNotificationCenter.current().add(request) { error in
      if let error = error {
        result(FlutterError(code: "notification_show_failed", message: error.localizedDescription, details: nil))
        return
      }
      result(true)
    }
  }
}
