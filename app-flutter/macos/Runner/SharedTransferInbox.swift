import Foundation
import UniformTypeIdentifiers

enum SharedTransferInbox {
  static let appGroupIdentifier = "group.com.example.appFlutter"
  private static let pendingPayloadKey = "rift.pendingSharePayload"
  private static let sharedDirectoryName = "SharedInbox"

  static func queueFiles(_ paths: [String]) {
    let items: [[String: String]] = paths.compactMap { path in
      let url = URL(fileURLWithPath: path)
      guard FileManager.default.fileExists(atPath: url.path) else {
        return nil
      }

      let fileName = url.lastPathComponent
      let mediaType: String
      if #available(macOS 11.0, *) {
        mediaType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
      } else {
        mediaType = "application/octet-stream"
      }

      return [
        "localPath": url.path,
        "fileName": fileName,
        "mediaType": mediaType,
      ]
    }

    guard !items.isEmpty else {
      return
    }

    queuePayload([
      "route": "history.send",
      "items": items,
    ])
  }

  static func queuePayload(_ payload: [String: Any]) {
    guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else {
      return
    }
    defaults.set(payload, forKey: pendingPayloadKey)
  }

  static func consumePendingPayload() -> [String: Any]? {
    guard let defaults = UserDefaults(suiteName: appGroupIdentifier),
          let payload = defaults.dictionary(forKey: pendingPayloadKey)
    else {
      return nil
    }

    defaults.removeObject(forKey: pendingPayloadKey)
    return payload
  }

  static func sharedInboxDirectory() throws -> URL {
    guard let container = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: appGroupIdentifier
    ) else {
      throw NSError(
        domain: "SharedTransferInbox",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Missing App Group container."]
      )
    }

    let directory = container.appendingPathComponent(sharedDirectoryName, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }
}
