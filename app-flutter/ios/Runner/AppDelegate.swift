import CoreLocation
import Flutter
import QuickLook
import Security
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, CLLocationManagerDelegate, FlutterImplicitEngineDelegate, QLPreviewControllerDataSource {
  private var identityChannel: FlutterMethodChannel?
  private var documentsChannel: FlutterMethodChannel?
  private var previewURL: NSURL?
  private var backgroundLocationManager: CLLocationManager?
  private var backgroundLocationActivationObserver: NSObjectProtocol?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let launched = super.application(
      application,
      didFinishLaunchingWithOptions: launchOptions
    )
    if Bundle.main.object(forInfoDictionaryKey: "RiftDevBackgroundLocationEnabled") as? Bool == true {
      backgroundLocationActivationObserver = NotificationCenter.default.addObserver(
        forName: UIApplication.didBecomeActiveNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        self?.startDevelopmentBackgroundLocation()
      }
    }
    return launched
  }

  private func startDevelopmentBackgroundLocation() {
    if let manager = backgroundLocationManager {
      updateDevelopmentBackgroundLocation(for: manager)
      return
    }

    let manager = CLLocationManager()
    manager.delegate = self
    manager.desiredAccuracy = kCLLocationAccuracyKilometer
    manager.distanceFilter = 1_000
    manager.activityType = .other
    manager.pausesLocationUpdatesAutomatically = false
    manager.allowsBackgroundLocationUpdates = true
    manager.showsBackgroundLocationIndicator = true
    backgroundLocationManager = manager

    updateDevelopmentBackgroundLocation(for: manager)
  }

  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    updateDevelopmentBackgroundLocation(for: manager)
  }

  private func updateDevelopmentBackgroundLocation(for manager: CLLocationManager) {
    switch locationAuthorizationStatus(for: manager) {
    case .authorizedAlways:
      manager.startUpdatingLocation()
    case .authorizedWhenInUse:
      manager.startUpdatingLocation()
      manager.requestAlwaysAuthorization()
    case .notDetermined:
      manager.requestWhenInUseAuthorization()
    case .denied, .restricted:
      break
    @unknown default:
      break
    }
  }

  private func locationAuthorizationStatus(for manager: CLLocationManager) -> CLAuthorizationStatus {
    if #available(iOS 14.0, *) {
      return manager.authorizationStatus
    }
    return CLLocationManager.authorizationStatus()
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    let channel = FlutterMethodChannel(
      name: "rift/ios/identity",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    channel.setMethodCallHandler { call, result in
      guard call.method == "loadOrCreate" else {
        result(FlutterMethodNotImplemented)
        return
      }

      do {
        let arguments = call.arguments as? [String: Any]
        let legacyPath = arguments?["legacyPath"] as? String
        let key = try Self.loadOrCreateIdentityKey(legacyPath: legacyPath)
        result(FlutterStandardTypedData(bytes: key))
      } catch {
        result(FlutterError(
          code: "identity_keychain_error",
          message: error.localizedDescription,
          details: nil
        ))
      }
    }
    identityChannel = channel

    let documentsChannel = FlutterMethodChannel(
      name: "rift/ios/documents",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    documentsChannel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(FlutterError(code: "unavailable", message: "Rift is unavailable.", details: nil))
        return
      }
      guard let arguments = call.arguments as? [String: Any],
            let path = arguments["path"] as? String,
            FileManager.default.fileExists(atPath: path) else {
        result(FlutterError(code: "file_not_found", message: "The saved file no longer exists.", details: nil))
        return
      }
      guard let presenter = self.activeViewController() else {
        result(FlutterError(code: "unavailable", message: "No active iOS window.", details: nil))
        return
      }

      let url = URL(fileURLWithPath: path)
      switch call.method {
      case "previewFile":
        self.previewURL = url as NSURL
        let preview = QLPreviewController()
        preview.dataSource = self
        presenter.present(preview, animated: true) {
          result(true)
        }
      case "exportFile":
        let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let popover = activity.popoverPresentationController {
          popover.sourceView = presenter.view
          popover.sourceRect = CGRect(
            x: presenter.view.bounds.midX,
            y: presenter.view.bounds.midY,
            width: 0,
            height: 0
          )
        }
        presenter.present(activity, animated: true) {
          result(true)
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    self.documentsChannel = documentsChannel
  }

  func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
    return previewURL == nil ? 0 : 1
  }

  func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
    return previewURL!
  }

  private func activeViewController() -> UIViewController? {
    let root = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }
      .first { $0.isKeyWindow }?
      .rootViewController
    return Self.topViewController(from: root)
  }

  private static func topViewController(from controller: UIViewController?) -> UIViewController? {
    if let presented = controller?.presentedViewController {
      return topViewController(from: presented)
    }
    if let navigation = controller as? UINavigationController {
      return topViewController(from: navigation.visibleViewController)
    }
    if let tab = controller as? UITabBarController {
      return topViewController(from: tab.selectedViewController)
    }
    return controller
  }

  private static let identityService = "dev.rift.identity.ed25519"
  private static let identityAccount = "device-seed"

  private static func loadOrCreateIdentityKey(legacyPath: String?) throws -> Data {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: identityService,
      kSecAttrAccount as String: identityAccount,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]

    var item: CFTypeRef?
    let lookupStatus = SecItemCopyMatching(query as CFDictionary, &item)
    if lookupStatus == errSecSuccess {
      guard let key = item as? Data, key.count == 32 else {
        throw IdentityKeyError.invalidKey
      }
      removeLegacyKey(at: legacyPath)
      return key
    }
    guard lookupStatus == errSecItemNotFound else {
      throw IdentityKeyError.keychainStatus(lookupStatus)
    }

    let key: Data
    if let legacyPath,
       let legacyKey = try? Data(contentsOf: URL(fileURLWithPath: legacyPath)),
       legacyKey.count == 32 {
      key = legacyKey
    } else {
      var bytes = [UInt8](repeating: 0, count: 32)
      let randomStatus = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
      guard randomStatus == errSecSuccess else {
        throw IdentityKeyError.keychainStatus(randomStatus)
      }
      key = Data(bytes)
    }

    let addQuery: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: identityService,
      kSecAttrAccount as String: identityAccount,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
      kSecValueData as String: key,
    ]
    let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
    guard addStatus == errSecSuccess else {
      throw IdentityKeyError.keychainStatus(addStatus)
    }

    removeLegacyKey(at: legacyPath)
    return key
  }

  private static func removeLegacyKey(at path: String?) {
    guard let path else { return }
    try? FileManager.default.removeItem(atPath: path)
  }
}

private enum IdentityKeyError: LocalizedError {
  case invalidKey
  case keychainStatus(OSStatus)

  var errorDescription: String? {
    switch self {
    case .invalidKey:
      return "Stored identity key is invalid."
    case .keychainStatus(let status):
      return SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)."
    }
  }
}
