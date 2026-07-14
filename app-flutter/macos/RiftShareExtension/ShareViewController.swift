import Cocoa
import Social
import UniformTypeIdentifiers

final class ShareViewController: SLComposeServiceViewController {
  override func isContentValid() -> Bool {
    true
  }

  override func didSelectPost() {
    Task {
      do {
        let items = try await collectSharedItems()
        SharedTransferInbox.queueSharedItems(items)
        openRiftApp()
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
      } catch {
        extensionContext?.cancelRequest(withError: error)
      }
    }
  }

  override func configurationItems() -> [Any]! {
    []
  }

  private func collectSharedItems() async throws -> [[String: String]] {
    guard let inputItems = extensionContext?.inputItems as? [NSExtensionItem] else {
      return []
    }

    var requests: [[String: String]] = []
    let inboxDirectory = try SharedTransferInbox.sharedInboxDirectory()

    for item in inputItems {
      for provider in item.attachments ?? [] {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
          if let request = try await importFile(provider: provider, inboxDirectory: inboxDirectory) {
            requests.append(request)
          }
          continue
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
          if let request = try await importText(provider: provider, inboxDirectory: inboxDirectory) {
            requests.append(request)
          }
        }
      }
    }

    return requests
  }

  private func importFile(
    provider: NSItemProvider,
    inboxDirectory: URL
  ) async throws -> [String: String]? {
    let loaded = try await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier)
    guard let fileURL = loaded as? URL else {
      return nil
    }

    let fileName = fileURL.lastPathComponent
    let destination = uniqueDestination(in: inboxDirectory, preferredName: fileName)
    try FileManager.default.copyItem(at: fileURL, to: destination)
    return [
      "localPath": destination.path,
      "fileName": fileName,
      "mediaType": SharedTransferInbox.mediaType(for: destination),
    ]
  }

  private func importText(
    provider: NSItemProvider,
    inboxDirectory: URL
  ) async throws -> [String: String]? {
    let loaded = try await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier)
    let text: String
    if let rawText = loaded as? String {
      text = rawText
    } else if let rawUrl = loaded as? URL {
      text = try String(contentsOf: rawUrl)
    } else {
      return nil
    }

    let fileName = "shared-text-\(UUID().uuidString).txt"
    let destination = inboxDirectory.appendingPathComponent(fileName)
    try text.write(to: destination, atomically: true, encoding: .utf8)
    return [
      "localPath": destination.path,
      "fileName": fileName,
      "mediaType": "text/plain",
    ]
  }

  private func uniqueDestination(in directory: URL, preferredName: String) -> URL {
    let sanitizedName = preferredName.isEmpty ? "shared-file" : preferredName
    let base = directory.appendingPathComponent(UUID().uuidString + "-" + sanitizedName)
    return base
  }

  private func openRiftApp() {
    guard let url = URL(string: "rift://history.send") else {
      return
    }
    NSWorkspace.shared.open(url)
  }
}

private extension NSItemProvider {
  func loadItem(forTypeIdentifier typeIdentifier: String) async throws -> NSSecureCoding? {
    try await withCheckedThrowingContinuation { continuation in
      loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, error in
        if let error {
          continuation.resume(throwing: error)
          return
        }
        continuation.resume(returning: item as? NSSecureCoding)
      }
    }
  }
}
