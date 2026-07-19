import Flutter
import Security
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var identityChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
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
