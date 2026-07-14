import Foundation
import UniformTypeIdentifiers

enum SharedTransferInbox {
  static let appGroupIdentifier = "group.com.example.appFlutter"
  private static let pendingPayloadKey = "rift.pendingSharePayload"
  private static let sharedDirectoryName = "SharedInbox"

  static func queueSharedItems(_ items: [[String: String]]) {
    guard !items.isEmpty else {
      return
    }
    guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else {
      return
    }
    defaults.set([
      "route": "history.send",
      "items": items,
    ], forKey: pendingPayloadKey)
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

  static func mediaType(for url: URL) -> String {
    if #available(macOS 11.0, *) {
      return UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }
    return "application/octet-stream"
  }
}
