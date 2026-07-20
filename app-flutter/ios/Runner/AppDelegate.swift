import AVFoundation
import CoreLocation
import Flutter
import MediaPlayer
import QuickLook
import Security
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, CLLocationManagerDelegate, FlutterImplicitEngineDelegate, QLPreviewControllerDataSource {
  private var identityChannel: FlutterMethodChannel?
  private var clipboardChannel: FlutterMethodChannel?
  private var documentsChannel: FlutterMethodChannel?
  private var notificationsChannel: FlutterMethodChannel?
  private var mediaPlaybackChannel: FlutterMethodChannel?
  private var mediaPlaybackCommandTargets: [Any] = []
  private var currentMediaPlaybackSourceDeviceId: String?
  private var currentMediaPlaybackId: String?
  private var currentMediaPlaybackState: String?
  private var currentMediaPlaybackInfo: [String: Any]?
  private var remoteMediaAudioPlayer: AVAudioPlayer?
  private var previewURL: NSURL?
  private var backgroundLocationManager: CLLocationManager?
  private var backgroundLocationActivationObserver: NSObjectProtocol?
  private var pendingNotificationAction: [String: Any]?
  private var notificationCallbacksReady = false

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    UNUserNotificationCenter.current().delegate = self
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

  private func showRemoteMediaPlayback(_ playback: [String: Any]) -> Bool {
    guard let sourceDeviceId = playback["sourceDeviceId"] as? String,
          !sourceDeviceId.isEmpty,
          let playbackId = playback["playbackId"] as? String,
          !playbackId.isEmpty else {
      return false
    }

    currentMediaPlaybackSourceDeviceId = sourceDeviceId
    currentMediaPlaybackId = playbackId
    currentMediaPlaybackState = playback["playbackState"] as? String
    _ = startDevelopmentRemoteMediaSession()

    var nowPlayingInfo: [String: Any] = [:]
    let appName = playback["appName"] as? String
    let title = playback["title"] as? String
    nowPlayingInfo[MPMediaItemPropertyTitle] = title?.isEmpty == false
      ? title
      : appName ?? "Remote playback"
    if let artist = playback["artist"] as? String, !artist.isEmpty {
      nowPlayingInfo[MPMediaItemPropertyArtist] = artist
    }
    if let album = playback["album"] as? String, !album.isEmpty {
      nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = album
    }
    if let durationMs = playback["durationMs"] as? NSNumber,
       durationMs.doubleValue >= 0 {
      nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = durationMs.doubleValue / 1_000
    }

    let positionMs = (playback["positionMs"] as? NSNumber)?.doubleValue ?? 0
    nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = max(0, positionMs / 1_000)
    let isPlaying = currentMediaPlaybackState == "playing"
    nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
    nowPlayingInfo[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
    nowPlayingInfo[MPNowPlayingInfoPropertyExternalContentIdentifier] =
      "\(sourceDeviceId):\(playbackId)"

    if let artwork = playback["artwork"] as? [String: Any],
       let dataBase64 = artwork["dataBase64"] as? String,
       let data = Data(base64Encoded: dataBase64),
       let image = UIImage(data: data) {
      nowPlayingInfo[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(
        boundsSize: image.size
      ) { _ in image }
    }

    configureMediaPlaybackCommandTargetsIfNeeded()
    updateMediaPlaybackCommandAvailability(playback)
    currentMediaPlaybackInfo = nowPlayingInfo
    reassertRemoteMediaPlaybackState()
    return true
  }

  private func clearRemoteMediaPlayback() {
    currentMediaPlaybackSourceDeviceId = nil
    currentMediaPlaybackId = nil
    currentMediaPlaybackState = nil
    currentMediaPlaybackInfo = nil
    MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    if #available(iOS 13.0, *) {
      MPNowPlayingInfoCenter.default().playbackState = .stopped
    }
    updateMediaPlaybackCommandAvailability([:])
    stopDevelopmentRemoteMediaSession()
  }

  private func reassertRemoteMediaPlaybackState() {
    guard let nowPlayingInfo = currentMediaPlaybackInfo else {
      return
    }

    let infoCenter = MPNowPlayingInfoCenter.default()
    infoCenter.nowPlayingInfo = nowPlayingInfo
    if #available(iOS 13.0, *) {
      switch currentMediaPlaybackState {
      case "playing":
        infoCenter.playbackState = .playing
      case "paused":
        infoCenter.playbackState = .paused
      case "buffering":
        infoCenter.playbackState = .interrupted
      case "stopped":
        infoCenter.playbackState = .stopped
      default:
        infoCenter.playbackState = .unknown
      }
    }
    syncDevelopmentRemoteMediaSessionPlaybackState()
  }

  private func startDevelopmentRemoteMediaSession() -> Bool {
    guard Bundle.main.object(
      forInfoDictionaryKey: "RiftDevRemoteMediaSessionEnabled"
    ) as? Bool == true else {
      return false
    }
    if remoteMediaAudioPlayer != nil {
      return true
    }

    do {
      let audioSession = AVAudioSession.sharedInstance()
      try audioSession.setCategory(.playback, mode: .default, options: [])
      try audioSession.setActive(true)
      let player = try AVAudioPlayer(
        data: Self.silentWaveData(),
        fileTypeHint: AVFileType.wav.rawValue
      )
      player.numberOfLoops = -1
      player.volume = 1
      player.prepareToPlay()
      guard player.play() else {
        try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
        return false
      }
      remoteMediaAudioPlayer = player
      UIApplication.shared.beginReceivingRemoteControlEvents()
      return true
    } catch {
      NSLog("Rift failed to start development remote media session: %@", error.localizedDescription)
      return false
    }
  }

  private func syncDevelopmentRemoteMediaSessionPlaybackState() {
    guard let player = remoteMediaAudioPlayer else {
      return
    }
    if currentMediaPlaybackState == "playing" {
      if !player.isPlaying {
        player.play()
      }
    } else if player.isPlaying {
      player.pause()
    }
  }

  private func stopDevelopmentRemoteMediaSession() {
    guard remoteMediaAudioPlayer != nil else {
      return
    }
    remoteMediaAudioPlayer?.stop()
    remoteMediaAudioPlayer = nil
    UIApplication.shared.endReceivingRemoteControlEvents()
    try? AVAudioSession.sharedInstance().setActive(
      false,
      options: .notifyOthersOnDeactivation
    )
  }

  private static func silentWaveData() -> Data {
    let sampleRate: UInt32 = 8_000
    let sampleCount: UInt32 = 800
    var data = Data()

    func append(_ value: UInt16) {
      var littleEndian = value.littleEndian
      withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
    func append(_ value: UInt32) {
      var littleEndian = value.littleEndian
      withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    data.append(contentsOf: "RIFF".utf8)
    append(36 + sampleCount)
    data.append(contentsOf: "WAVEfmt ".utf8)
    append(UInt32(16))
    append(UInt16(1))
    append(UInt16(1))
    append(sampleRate)
    append(sampleRate)
    append(UInt16(1))
    append(UInt16(8))
    data.append(contentsOf: "data".utf8)
    append(sampleCount)
    data.append(Data(repeating: 128, count: Int(sampleCount)))
    return data
  }

  private func configureMediaPlaybackCommandTargetsIfNeeded() {
    guard mediaPlaybackCommandTargets.isEmpty else {
      return
    }

    let commands = MPRemoteCommandCenter.shared()
    mediaPlaybackCommandTargets.append(
      commands.playCommand.addTarget { [weak self] _ in
        self?.dispatchMediaPlaybackAction("play") ?? .noSuchContent
      }
    )
    mediaPlaybackCommandTargets.append(
      commands.pauseCommand.addTarget { [weak self] _ in
        self?.dispatchMediaPlaybackAction("pause") ?? .noSuchContent
      }
    )
    mediaPlaybackCommandTargets.append(
      commands.nextTrackCommand.addTarget { [weak self] _ in
        self?.dispatchMediaPlaybackAction("next") ?? .noSuchContent
      }
    )
    mediaPlaybackCommandTargets.append(
      commands.previousTrackCommand.addTarget { [weak self] _ in
        self?.dispatchMediaPlaybackAction("previous") ?? .noSuchContent
      }
    )
    mediaPlaybackCommandTargets.append(
      commands.togglePlayPauseCommand.addTarget { [weak self] _ in
        guard let self else {
          return .noSuchContent
        }
        return self.dispatchMediaPlaybackAction(
          self.currentMediaPlaybackState == "playing" ? "pause" : "play"
        )
      }
    )
    mediaPlaybackCommandTargets.append(
      commands.changePlaybackPositionCommand.addTarget { [weak self] event in
        guard let positionEvent = event as? MPChangePlaybackPositionCommandEvent else {
          return .commandFailed
        }
        return self?.dispatchMediaPlaybackAction(
          "seek",
          positionMs: Int((positionEvent.positionTime * 1_000).rounded())
        ) ?? .noSuchContent
      }
    )
  }

  private func updateMediaPlaybackCommandAvailability(_ playback: [String: Any]) {
    let commands = MPRemoteCommandCenter.shared()
    commands.playCommand.isEnabled = playback["canPlay"] as? Bool == true
    commands.pauseCommand.isEnabled = playback["canPause"] as? Bool == true
    commands.togglePlayPauseCommand.isEnabled =
      commands.playCommand.isEnabled || commands.pauseCommand.isEnabled
    commands.nextTrackCommand.isEnabled = playback["canSkipNext"] as? Bool == true
    commands.previousTrackCommand.isEnabled = playback["canSkipPrevious"] as? Bool == true
    commands.changePlaybackPositionCommand.isEnabled = playback["canSeek"] as? Bool == true
    commands.skipForwardCommand.isEnabled = false
    commands.skipBackwardCommand.isEnabled = false
    commands.changePlaybackRateCommand.isEnabled = false
  }

  private func dispatchMediaPlaybackAction(
    _ action: String,
    positionMs: Int? = nil
  ) -> MPRemoteCommandHandlerStatus {
    guard let sourceDeviceId = currentMediaPlaybackSourceDeviceId,
          let playbackId = currentMediaPlaybackId,
          let channel = mediaPlaybackChannel else {
      return .noSuchContent
    }

    var payload: [String: Any] = [
      "sourceDeviceId": sourceDeviceId,
      "playbackId": playbackId,
      "action": action,
    ]
    if let positionMs {
      payload["positionMs"] = positionMs
    }
    channel.invokeMethod("mediaPlaybackAction", arguments: payload) { [weak self] _ in
      self?.reassertRemoteMediaPlaybackState()
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(150)) { [weak self] in
      self?.reassertRemoteMediaPlaybackState()
    }
    return .success
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    let mediaPlaybackChannel = FlutterMethodChannel(
      name: "rift/ios/media_playback",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    mediaPlaybackChannel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(false)
        return
      }
      switch call.method {
      case "show":
        guard let arguments = call.arguments as? [String: Any],
              let playback = arguments["playback"] as? [String: Any] else {
          result(false)
          return
        }
        result(self.showRemoteMediaPlayback(playback))
      case "clear":
        self.clearRemoteMediaPlayback()
        result(true)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    self.mediaPlaybackChannel = mediaPlaybackChannel

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

    let clipboardChannel = FlutterMethodChannel(
      name: "rift/ios/clipboard",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    clipboardChannel.setMethodCallHandler { call, result in
      let pasteboard = UIPasteboard.general
      switch call.method {
      case "readContent":
        if let image = pasteboard.image, let data = image.pngData() {
          result([
            "contentType": "image/png",
            "bytes": FlutterStandardTypedData(bytes: data),
          ])
        } else if let text = pasteboard.string, let data = text.data(using: .utf8) {
          result([
            "contentType": "text/plain",
            "bytes": FlutterStandardTypedData(bytes: data),
          ])
        } else {
          result(nil)
        }
      case "writeContent":
        guard let arguments = call.arguments as? [String: Any],
              let contentType = arguments["contentType"] as? String,
              let typedData = arguments["bytes"] as? FlutterStandardTypedData else {
          result(FlutterError(code: "invalid_args", message: "contentType and bytes are required.", details: nil))
          return
        }

        switch contentType {
        case "text/plain", "clipboard":
          guard let text = String(data: typedData.data, encoding: .utf8) else {
            result(false)
            return
          }
          pasteboard.string = text
          result(true)
        case "image/png":
          guard let image = UIImage(data: typedData.data) else {
            result(false)
            return
          }
          pasteboard.image = image
          result(true)
        default:
          result(false)
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    self.clipboardChannel = clipboardChannel

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

    let notificationsChannel = FlutterMethodChannel(
      name: "rift/ios/notifications",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    notificationsChannel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(FlutterError(code: "unavailable", message: "Rift is unavailable.", details: nil))
        return
      }

      let notificationCenter = UNUserNotificationCenter.current()
      switch call.method {
      case "getPermissionStatus":
        notificationCenter.getNotificationSettings { settings in
          let status: String
          switch settings.authorizationStatus {
          case .notDetermined:
            status = "notDetermined"
          case .denied:
            status = "denied"
          case .authorized, .provisional:
            status = "authorized"
          @unknown default:
            status = "unknown"
          }
          DispatchQueue.main.async {
            result(status)
          }
        }
      case "requestPermission":
        notificationCenter.requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
          DispatchQueue.main.async {
            if let error {
              result(FlutterError(code: "notification_permission", message: error.localizedDescription, details: nil))
            } else {
              result(granted)
            }
          }
        }
      case "showNotification":
        guard let arguments = call.arguments as? [String: Any],
              let title = arguments["title"] as? String,
              let body = arguments["body"] as? String else {
          result(FlutterError(code: "invalid_args", message: "title and body are required.", details: nil))
          return
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        var userInfo = arguments["payload"] as? [String: Any] ?? [:]
        if let route = arguments["route"] as? String {
          userInfo["route"] = route
        }
        if let destinationPath = arguments["destinationPath"] as? String {
          userInfo["destinationPath"] = destinationPath
        }
        content.userInfo = userInfo
        let request = UNNotificationRequest(
          identifier: UUID().uuidString.lowercased(),
          content: content,
          trigger: nil
        )
        notificationCenter.add(request) { error in
          DispatchQueue.main.async {
            if let error {
              result(FlutterError(code: "notification_show", message: error.localizedDescription, details: nil))
            } else {
              result(true)
            }
          }
        }
      case "openSettings":
        guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else {
          result(false)
          return
        }
        UIApplication.shared.open(settingsURL, options: [:]) { opened in
          result(opened)
        }
      case "consumeLaunchAction":
        self.notificationCallbacksReady = true
        result(self.pendingNotificationAction)
        self.pendingNotificationAction = nil
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    self.notificationsChannel = notificationsChannel
  }

  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    if #available(iOS 14.0, *) {
      completionHandler([.banner, .list, .sound])
    } else {
      completionHandler([.alert, .sound])
    }
  }

  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    var payload: [String: Any] = [:]
    for (key, value) in response.notification.request.content.userInfo {
      if let key = key as? String {
        payload[key] = value
      }
    }

    if notificationCallbacksReady {
      notificationsChannel?.invokeMethod("notificationActivated", arguments: payload)
    } else {
      pendingNotificationAction = payload
    }
    completionHandler()
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
