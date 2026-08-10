import Cocoa
import FlutterMacOS

final class SendFilesBridge: NSObject {
    static let channelName = "rift/macos/send_files"
    static let callbackMethod = "sendFilesSelected"
    static let shared = SendFilesBridge()

    private var channel: FlutterMethodChannel?
    private weak var hostWindow: NSWindow?

    func register(with messenger: FlutterBinaryMessenger, window: NSWindow?) {
        hostWindow = window
        let channel = FlutterMethodChannel(name: Self.channelName, binaryMessenger: messenger)
        self.channel = channel
        channel.setMethodCallHandler(handle)
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "pickSendFiles":
            presentSendFilesPanel(forMenuAction: false, result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    func presentSendFilesPanel(forMenuAction: Bool, result: FlutterResult? = nil) {
        DispatchQueue.main.async {
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = true
            panel.resolvesAliases = true
            panel.treatsFilePackagesAsDirectories = false
            panel.title = "Send Files"
            panel.prompt = "Send"

            let completionHandler: (NSApplication.ModalResponse) -> Void = { response in
                let items = response == .OK ? self.selectionItems(from: panel.urls) : []
                if forMenuAction {
                    self.channel?.invokeMethod(Self.callbackMethod, arguments: items)
                    result?(nil)
                    return
                }

                result?(items)
            }

            if let window = self.hostWindow {
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                panel.beginSheetModal(for: window, completionHandler: completionHandler)
            } else {
                let response = panel.runModal()
                completionHandler(response)
            }
        }
    }

    private func selectionItems(from urls: [URL]) -> [[String: String]] {
        urls.compactMap { url in
            guard url.isFileURL else {
                return nil
            }

            let path = url.path
            guard !path.isEmpty else {
                return nil
            }

            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                return nil
            }

            guard FileManager.default.isReadableFile(atPath: path) else {
                return nil
            }

            return [
                "localPath": path,
                "fileName": url.lastPathComponent,
            ]
        }
    }
}
