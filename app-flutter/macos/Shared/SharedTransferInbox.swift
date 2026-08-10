import Foundation
import UniformTypeIdentifiers

/// Shared persistence + App Group plumbing used by both the host app target
/// (`Runner`) and the share extension (`RiftShareExtension`).
///
/// The single source of truth for the App Group identifier and the pending
/// payload key lives here so the two targets cannot drift.
enum SharedTransferInbox {
  static let appGroupIdentifier = "group.dev.rift.app"
  private static let pendingPayloadKey = "rift.pendingSharePayload"
  private static let sharedDirectoryName = "SharedInbox"

  // MARK: - Public API

  /// Convert a list of filesystem paths into share queue items and persist
  /// them as a `history.send` payload.
  ///
  /// Missing files are silently filtered out; callers do not get per-path
  /// feedback.
  static func queueFiles(_ paths: [String]) {
    let items: [[String: String]] = paths.compactMap { path in
      let url = URL(fileURLWithPath: path)
      guard FileManager.default.fileExists(atPath: url.path) else {
        return nil
      }

      return [
        "localPath": url.path,
        "fileName": url.lastPathComponent,
        "mediaType": mediaType(for: url),
      ]
    }

    queueSharedItems(items)
  }

  /// Persist a list of already-built share queue items as a
  /// `history.send` payload. No-op when `items` is empty or the App Group
  /// preferences are unavailable.
  static func queueSharedItems(_ items: [[String: String]]) {
    guard !items.isEmpty else {
      return
    }
    queuePayload([
      "route": "history.send",
      "items": items,
    ])
  }

  /// Persist a fully-formed payload under the pending-payload key. Used by
  /// `queueSharedItems` and available for any other route that needs to
  /// hand a payload from the extension or the host to the host.
  static func queuePayload(_ payload: [String: Any]) {
    guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else {
      return
    }
    defaults.set(payload, forKey: pendingPayloadKey)
  }

  /// Read and clear the pending payload. Returns nil if none is queued or
  /// the App Group is unavailable.
  static func consumePendingPayload() -> [String: Any]? {
    guard let defaults = UserDefaults(suiteName: appGroupIdentifier),
          let payload = defaults.dictionary(forKey: pendingPayloadKey)
    else {
      return nil
    }

    defaults.removeObject(forKey: pendingPayloadKey)
    return payload
  }

  /// Resolve the App Group's shared inbox directory, creating it on demand.
  /// Throws if the container cannot be obtained (e.g., the entitlement is
  /// missing or has not been provisioned yet).
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

  /// Best-effort MIME type lookup for a filesystem URL.
  static func mediaType(for url: URL) -> String {
    if #available(macOS 11.0, *) {
      return UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
        ?? "application/octet-stream"
    }
    return "application/octet-stream"
  }
}