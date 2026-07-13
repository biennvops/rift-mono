import Foundation
import Cocoa
import CryptoKit
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

final class DesktopClipboardBridge {
  static let channelName = "rift/desktop/clipboard"
  private var lastReadFingerprint: String?

  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    let instance = DesktopClipboardBridge()
    channel.setMethodCallHandler(instance.handle)
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getClipboardContent":
      getClipboardContent(result: result)
    case "setClipboardContent":
      setClipboardContent(args: call.arguments, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func getClipboardContent(result: @escaping FlutterResult) {
    let pasteboard = NSPasteboard.general
    if let pngData = normalizedPngData(from: pasteboard) {
      logReadIfChanged(contentType: "image/png", data: pngData)
      result([
        "contentType": "image/png",
        "bytes": FlutterStandardTypedData(bytes: pngData),
      ])
      return
    }

    if let text = pasteboard.string(forType: .string),
       let data = text.data(using: .utf8) {
      logReadIfChanged(contentType: "text/plain", data: data)
      result([
        "contentType": "text/plain",
        "bytes": FlutterStandardTypedData(bytes: data),
      ])
      return
    }

    logEmptyReadIfChanged()
    result(nil)
  }

  private func setClipboardContent(args: Any?, result: @escaping FlutterResult) {
    guard
      let dict = args as? [String: Any],
      let contentType = dict["contentType"] as? String,
      let typedData = dict["bytes"] as? FlutterStandardTypedData
    else {
      result(FlutterError(code: "invalid_args", message: "contentType and bytes are required", details: nil))
      return
    }

    switch contentType {
    case "text/plain", "clipboard":
      guard let text = String(data: typedData.data, encoding: .utf8) else {
        NSLog("Rift clipboard bridge: failed to decode text/plain payload")
        result(false)
        return
      }
      let pasteboard = NSPasteboard.general
      pasteboard.clearContents()
      let applied = pasteboard.setString(text, forType: .string)
      NSLog("Rift clipboard bridge: wrote text/plain payload (%lu bytes) success=%@", typedData.data.count, applied.description)
      result(applied)
    case "image/png":
      let pasteboard = NSPasteboard.general
      pasteboard.clearContents()
      let applied = pasteboard.setData(typedData.data, forType: .png)
      NSLog("Rift clipboard bridge: wrote image/png payload (%lu bytes) success=%@", typedData.data.count, applied.description)
      result(applied)
    default:
      NSLog("Rift clipboard bridge: unsupported write content type %@", contentType)
      result(false)
    }
  }

  private func normalizedPngData(from pasteboard: NSPasteboard) -> Data? {
    if let pngData = pasteboard.data(forType: .png) {
      return pngData
    }

    guard
      let image = NSImage(pasteboard: pasteboard),
      let tiffData = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiffData),
      let pngData = bitmap.representation(using: .png, properties: [:])
    else {
      return nil
    }

    return pngData
  }

  private func logReadIfChanged(contentType: String, data: Data) {
    let fingerprint = "\(contentType):\(data.count):\(sha256Hex(data))"
    guard fingerprint != lastReadFingerprint else {
      return
    }

    lastReadFingerprint = fingerprint
    NSLog("Rift clipboard bridge: read %@ payload (%lu bytes)", contentType, data.count)
  }

  private func logEmptyReadIfChanged() {
    guard lastReadFingerprint != "empty" else {
      return
    }

    lastReadFingerprint = "empty"
    NSLog("Rift clipboard bridge: no supported clipboard payload available")
  }

  private func sha256Hex(_ data: Data) -> String {
    let digest = SHA256.hash(data: data)
    return digest.map { String(format: "%02x", $0) }.joined()
  }
}
