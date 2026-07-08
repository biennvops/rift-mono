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

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
