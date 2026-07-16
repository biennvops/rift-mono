import Cocoa
import CryptoKit
import FlutterMacOS
import Foundation
import UserNotifications

final class PermissionsBridge: NSObject, UNUserNotificationCenterDelegate {
  static let channelName = "rift.permissions"
  private static let shared = PermissionsBridge()
  private static var channel: FlutterMethodChannel?
  private static var pendingAction: [String: Any]?

  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    Self.channel = channel
    channel.setMethodCallHandler(Self.shared.handle)
    UNUserNotificationCenter.current().delegate = Self.shared
    Self.flushPendingActionIfNeeded()
  }

  static func dispatchOpenFiles(_ paths: [String]) {
    SharedTransferInbox.queueFiles(paths)
    guard let payload = SharedTransferInbox.consumePendingPayload() else {
      return
    }
    dispatchPayload(payload)
  }

  static func dispatchRoute(_ route: String) {
    dispatchPayload(["route": route])
  }

  private static func flushPendingActionIfNeeded() {
    guard let payload = pendingAction, let channel = channel else {
      return
    }
    pendingAction = nil
    DispatchQueue.main.async {
      channel.invokeMethod("notificationActivated", arguments: payload)
    }
  }

  private static func dispatchPayload(_ payload: [String: Any]) {
    if let channel = Self.channel {
      DispatchQueue.main.async {
        channel.invokeMethod("notificationActivated", arguments: payload)
      }
    } else {
      Self.pendingAction = payload
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "notification.getStatus":
      getNotificationStatus(result: result)
    case "notification.request":
      requestNotification(result: result)
    case "notification.show":
      showNotification(args: call.arguments, result: result)
    case "share.consumePendingItems":
      result(SharedTransferInbox.consumePendingPayload())
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func getNotificationStatus(result: @escaping FlutterResult) {
    UNUserNotificationCenter.current().getNotificationSettings { settings in
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
    UNUserNotificationCenter.current().requestAuthorization(
      options: [.alert, .badge, .sound]
    ) { granted, error in
      if let error = error {
        result(
          FlutterError(
            code: "notification_request_failed",
            message: error.localizedDescription,
            details: nil
          )
        )
        return
      }
      result(granted)
    }
  }

  private func showNotification(args: Any?, result: @escaping FlutterResult) {
    let dict = args as? [String: Any]
    let title = dict?["title"] as? String ?? "Rift"
    let body = dict?["body"] as? String ?? ""
    let route = dict?["route"] as? String
    let payload = dict?["payload"] as? [String: Any]

    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.sound = .default
    if let route = route {
      var userInfo: [AnyHashable: Any] = ["route": route]
      if let payload = payload {
        for (key, value) in payload {
          userInfo[key] = value
        }
      }
      content.userInfo = userInfo
    }

    let request = UNNotificationRequest(
      identifier: UUID().uuidString,
      content: content,
      trigger: nil
    )

    UNUserNotificationCenter.current().add(request) { error in
      if let error = error {
        result(
          FlutterError(
            code: "notification_show_failed",
            message: error.localizedDescription,
            details: nil
          )
        )
        return
      }
      result(true)
    }
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let userInfo = response.notification.request.content.userInfo
    guard let route = userInfo["route"] as? String else {
      completionHandler()
      return
    }

    var payload: [String: Any] = ["route": route]
    for (key, value) in userInfo {
      guard let stringKey = key as? String, stringKey != "route" else {
        continue
      }
      payload[stringKey] = value
    }

    Self.dispatchPayload(payload)
    completionHandler()
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
       let data = text.data(using: .utf8)
    {
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
      result(
        FlutterError(
          code: "invalid_args",
          message: "contentType and bytes are required",
          details: nil
        )
      )
      return
    }

    switch contentType {
    case "text/plain", "clipboard":
      guard let text = String(data: typedData.data, encoding: .utf8) else {
        NSLog("Rift clipboard bridge: failed to decode text/plain payload")
        result(false)
        return
      }

      let item = NSPasteboardItem()
      guard item.setString(text, forType: .string) else {
        NSLog("Rift clipboard bridge: failed to stage text/plain payload")
        result(false)
        return
      }

      let pasteboard = NSPasteboard.general
      let applied = pasteboard.writeObjects([item])
      NSLog(
        "Rift clipboard bridge: wrote text/plain payload (%lu bytes) success=%@",
        typedData.data.count,
        applied.description
      )
      result(applied)
    case "image/png":
      let item = NSPasteboardItem()
      guard item.setData(typedData.data, forType: .png) else {
        NSLog("Rift clipboard bridge: failed to stage image/png payload")
        result(false)
        return
      }

      let pasteboard = NSPasteboard.general
      let applied = pasteboard.writeObjects([item])
      NSLog(
        "Rift clipboard bridge: wrote image/png payload (%lu bytes) success=%@",
        typedData.data.count,
        applied.description
      )
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
