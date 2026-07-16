import Cocoa
import Darwin
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
    private static var singleInstanceLockFileDescriptor: CInt = -1

    private func acquireSingleInstanceLock() -> Bool {
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.example.appFlutter"
        let sanitizedBundleIdentifier = bundleIdentifier.replacingOccurrences(of: "/", with: "_")
        let lockPath = "\(NSTemporaryDirectory())\(sanitizedBundleIdentifier).lock"
        let descriptor = open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor != -1 else {
            return true
        }

        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
            AppDelegate.singleInstanceLockFileDescriptor = descriptor
            return true
        }

        close(descriptor)
        return false
    }

    override func applicationWillFinishLaunching(_ notification: Notification) {
        super.applicationWillFinishLaunching(notification)

        NSApp.setActivationPolicy(.regular)

        guard acquireSingleInstanceLock() else {
            NSApp.terminate(nil)
            return
        }
    }

    override func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        return true
    }

    override func applicationSupportsSecureRestorableState(_: NSApplication) -> Bool {
        return true
    }

    @IBAction func sendFilesMenuAction(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        mainFlutterWindow?.makeKeyAndOrderFront(sender)
        SendFilesBridge.shared.presentSendFilesPanel(forMenuAction: true)
    }

    override func application(_ sender: NSApplication, openFiles filenames: [String]) {
        PermissionsBridge.dispatchOpenFiles(filenames)
        sender.reply(toOpenOrPrint: .success)
    }

    override func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "rift" {
            PermissionsBridge.dispatchRoute(url.host ?? url.absoluteString.replacingOccurrences(of: "rift://", with: ""))
        }
    }
}
