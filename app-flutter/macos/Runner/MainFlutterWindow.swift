import Cocoa
import FlutterMacOS
import window_manager

class MainFlutterWindow: NSWindow {
    override func awakeFromNib() {
        let flutterViewController = FlutterViewController()
        let windowFrame = frame
        contentViewController = flutterViewController
        setFrame(windowFrame, display: true)

        RegisterGeneratedPlugins(registry: flutterViewController)
        PermissionsBridge.register(with: flutterViewController.engine.binaryMessenger)
        DesktopClipboardBridge.register(with: flutterViewController.engine.binaryMessenger)
        MacOSMediaPlaybackBridge.register(with: flutterViewController.engine.binaryMessenger)
        SendFilesBridge.shared.register(
            with: flutterViewController.engine.binaryMessenger,
            window: self
        )

        super.awakeFromNib()
    }

    override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
        super.order(place, relativeTo: otherWin)
        hiddenWindowAtLaunch()
    }
}
