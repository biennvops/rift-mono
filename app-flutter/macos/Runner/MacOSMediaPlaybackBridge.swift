import AppKit
import Darwin
import FlutterMacOS
import Foundation
import MediaPlayer

final class MacOSMediaPlaybackBridge: NSObject, FlutterStreamHandler {
  private static let methodChannelName = "rift/macos/media_playback"
  private static let eventChannelName = "rift/macos/media_playback_events"
  private static let remoteContentIdentifierPrefix = "rift.remote:"

  private let mediaRemote = MediaRemoteController()
  private let workQueue = DispatchQueue(label: "dev.rift.macos.mediaPlayback")
  private var eventSink: FlutterEventSink?
  private var pollTimer: DispatchSourceTimer?
  private var lastSnapshot: MediaPlaybackSnapshot?
  private var lastFingerprint: String?
  private var methodChannel: FlutterMethodChannel?
  private var currentRemoteSourceDeviceId: String?
  private var currentRemotePlaybackId: String?
  private var currentRemotePlaybackState: String?
  private var currentRemoteNowPlayingInfo: [String: Any]?
  private var remoteCommandTargets: [Any] = []

  static func register(with messenger: FlutterBinaryMessenger) {
    let bridge = MacOSMediaPlaybackBridge()
    let methodChannel = FlutterMethodChannel(
      name: methodChannelName,
      binaryMessenger: messenger
    )
    let eventChannel = FlutterEventChannel(
      name: eventChannelName,
      binaryMessenger: messenger
    )
    bridge.methodChannel = methodChannel
    eventChannel.setStreamHandler(bridge)
    methodChannel.setMethodCallHandler(bridge.handle)
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "startObservation":
      startObservation()
      result(true)
    case "stopObservation":
      stopObservation()
      result(true)
    case "showRemotePlayback":
      guard let args = call.arguments as? [String: Any],
            let playback = args["playback"] as? [String: Any] else {
        result(false)
        return
      }
      result(showRemotePlayback(playback))
    case "clearRemotePlayback":
      clearRemotePlayback()
      result(true)
    case "performAction":
      guard let args = call.arguments as? [String: Any],
            let action = args["action"] as? String else {
        result([
          "success": false,
          "failureReason": "MalformedMessage",
          "message": "action is required",
        ])
        return
      }
      let positionMs = (args["positionMs"] as? NSNumber)?.intValue
      result(mediaRemote.performAction(action: action, positionMs: positionMs))
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func startObservation() {
    guard pollTimer == nil else {
      return
    }

    let timer = DispatchSource.makeTimerSource(queue: workQueue)
    timer.schedule(deadline: .now(), repeating: .seconds(1))
    timer.setEventHandler { [weak self] in
      self?.poll()
    }
    pollTimer = timer
    timer.resume()
  }

  private func stopObservation() {
    pollTimer?.cancel()
    pollTimer = nil
    lastSnapshot = nil
    lastFingerprint = nil
  }

  private func showRemotePlayback(_ playback: [String: Any]) -> Bool {
    guard let sourceDeviceId = playback["sourceDeviceId"] as? String,
          !sourceDeviceId.isEmpty,
          let playbackId = playback["playbackId"] as? String,
          !playbackId.isEmpty else {
      return false
    }

    currentRemoteSourceDeviceId = sourceDeviceId
    currentRemotePlaybackId = playbackId
    currentRemotePlaybackState = playback["playbackState"] as? String

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
    nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] =
      currentRemotePlaybackState == "playing" ? 1.0 : 0.0
    nowPlayingInfo[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
    nowPlayingInfo[MPNowPlayingInfoPropertyExternalContentIdentifier] =
      "rift.remote:\(sourceDeviceId):\(playbackId)"

    if let artwork = playback["artwork"] as? [String: Any],
       let dataBase64 = artwork["dataBase64"] as? String,
       let data = Data(base64Encoded: dataBase64),
       let image = NSImage(data: data) {
      nowPlayingInfo[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(
        boundsSize: image.size
      ) { _ in image }
    }

    configureRemoteCommandTargetsIfNeeded()
    updateRemoteCommandAvailability(playback)
    currentRemoteNowPlayingInfo = nowPlayingInfo
    reassertRemotePlaybackState()
    return true
  }

  private func clearRemotePlayback() {
    let infoCenter = MPNowPlayingInfoCenter.default()
    let contentIdentifier = infoCenter.nowPlayingInfo?[MPNowPlayingInfoPropertyExternalContentIdentifier] as? String
    let ownsNowPlayingEntry =
      contentIdentifier?.hasPrefix(Self.remoteContentIdentifierPrefix) == true

    currentRemoteSourceDeviceId = nil
    currentRemotePlaybackId = nil
    currentRemotePlaybackState = nil
    currentRemoteNowPlayingInfo = nil
    if ownsNowPlayingEntry {
      infoCenter.nowPlayingInfo = nil
      infoCenter.playbackState = .stopped
    }
    updateRemoteCommandAvailability([:])
  }

  private func reassertRemotePlaybackState() {
    guard let nowPlayingInfo = currentRemoteNowPlayingInfo else {
      return
    }

    let infoCenter = MPNowPlayingInfoCenter.default()
    infoCenter.nowPlayingInfo = nowPlayingInfo
    switch currentRemotePlaybackState {
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

  private func configureRemoteCommandTargetsIfNeeded() {
    guard remoteCommandTargets.isEmpty else {
      return
    }

    let commands = MPRemoteCommandCenter.shared()
    remoteCommandTargets.append(
      commands.playCommand.addTarget { [weak self] _ in
        self?.dispatchRemotePlaybackAction("play") ?? .noSuchContent
      }
    )
    remoteCommandTargets.append(
      commands.pauseCommand.addTarget { [weak self] _ in
        self?.dispatchRemotePlaybackAction("pause") ?? .noSuchContent
      }
    )
    remoteCommandTargets.append(
      commands.togglePlayPauseCommand.addTarget { [weak self] _ in
        guard let self else {
          return .noSuchContent
        }
        return self.dispatchRemotePlaybackAction("togglePlayPause")
      }
    )
    remoteCommandTargets.append(
      commands.nextTrackCommand.addTarget { [weak self] _ in
        self?.dispatchRemotePlaybackAction("next") ?? .noSuchContent
      }
    )
    remoteCommandTargets.append(
      commands.previousTrackCommand.addTarget { [weak self] _ in
        self?.dispatchRemotePlaybackAction("previous") ?? .noSuchContent
      }
    )
    remoteCommandTargets.append(
      commands.changePlaybackPositionCommand.addTarget { [weak self] event in
        guard let positionEvent = event as? MPChangePlaybackPositionCommandEvent else {
          return .commandFailed
        }
        return self?.dispatchRemotePlaybackAction(
          "seek",
          positionMs: Int((positionEvent.positionTime * 1_000).rounded())
        ) ?? .noSuchContent
      }
    )
  }

  private func updateRemoteCommandAvailability(_ playback: [String: Any]) {
    let commands = MPRemoteCommandCenter.shared()
    commands.playCommand.isEnabled = playback["canPlay"] as? Bool == true
    commands.pauseCommand.isEnabled = playback["canPause"] as? Bool == true
    commands.togglePlayPauseCommand.isEnabled =
      commands.playCommand.isEnabled || commands.pauseCommand.isEnabled
    commands.nextTrackCommand.isEnabled = playback["canSkipNext"] as? Bool == true
    commands.previousTrackCommand.isEnabled = playback["canSkipPrevious"] as? Bool == true
    commands.changePlaybackPositionCommand.isEnabled = playback["canSeek"] as? Bool == true
  }

  private func dispatchRemotePlaybackAction(
    _ action: String,
    positionMs: Int? = nil
  ) -> MPRemoteCommandHandlerStatus {
    guard let sourceDeviceId = currentRemoteSourceDeviceId,
          let playbackId = currentRemotePlaybackId,
          let channel = methodChannel else {
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

    DispatchQueue.main.async { [weak self] in
      channel.invokeMethod("mediaPlaybackAction", arguments: payload) { _ in
        self?.reassertRemotePlaybackState()
      }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(150)) { [weak self] in
      self?.reassertRemotePlaybackState()
    }
    return .success
  }

  private func poll() {
    mediaRemote.fetchSnapshot { [weak self] snapshot in
      guard let self else {
        return
      }
      DispatchQueue.main.async {
        self.publish(snapshot)
      }
    }
  }

  private func publish(_ snapshot: MediaPlaybackSnapshot?) {
    guard let sink = eventSink else {
      lastSnapshot = snapshot
      lastFingerprint = snapshot?.fingerprint
      return
    }

    guard let snapshot else {
      if let previous = lastSnapshot {
        sink([
          "eventType": "removed",
          "playbackId": previous.playbackId,
          "removedAt": isoTimestampNow(),
        ])
      }
      lastSnapshot = nil
      lastFingerprint = nil
      return
    }

    let eventType = lastSnapshot == nil || lastSnapshot?.playbackId != snapshot.playbackId
      ? "posted"
      : "updated"

    if eventType == "updated" && lastFingerprint == snapshot.fingerprint {
      lastSnapshot = snapshot
      return
    }

    sink(snapshot.toEvent(eventType: eventType))
    lastSnapshot = snapshot
    lastFingerprint = snapshot.fingerprint
  }

  private func isoTimestampNow() -> String {
    ISO8601DateFormatter().string(from: Date())
  }
}

private struct MediaPlaybackSnapshot {
  let playbackId: String
  let sourcePlatform: String
  let appId: String
  let appName: String
  let title: String?
  let artist: String?
  let album: String?
  let playbackState: String
  let positionMs: Int
  let durationMs: Int?
  let canPlay: Bool
  let canPause: Bool
  let canSkipNext: Bool
  let canSkipPrevious: Bool
  let canSeek: Bool
  let updatedAt: String

  var fingerprint: String {
    let positionBucket = positionMs / 5000
    return [
      playbackId,
      appId,
      appName,
      title ?? "",
      artist ?? "",
      album ?? "",
      playbackState,
      String(positionBucket),
      String(durationMs ?? -1),
      String(canPlay),
      String(canPause),
      String(canSkipNext),
      String(canSkipPrevious),
      String(canSeek),
    ].joined(separator: "\n")
  }

  func toEvent(eventType: String) -> [String: Any] {
    var payload: [String: Any] = [
      "eventType": eventType,
      "playbackId": playbackId,
      "sourcePlatform": sourcePlatform,
      "appId": appId,
      "appName": appName,
      "playbackState": playbackState,
      "positionMs": positionMs,
      "canPlay": canPlay,
      "canPause": canPause,
      "canSkipNext": canSkipNext,
      "canSkipPrevious": canSkipPrevious,
      "canSeek": canSeek,
      "updatedAt": updatedAt,
    ]
    if let title, !title.isEmpty {
      payload["title"] = title
    }
    if let artist, !artist.isEmpty {
      payload["artist"] = artist
    }
    if let album, !album.isEmpty {
      payload["album"] = album
    }
    if let durationMs {
      payload["durationMs"] = durationMs
    }
    return payload
  }
}

private final class MediaRemoteController {
  func fetchSnapshot(completion: @escaping (MediaPlaybackSnapshot?) -> Void) {
    let metadata = MPNowPlayingInfoCenter.default().nowPlayingInfo
    guard let metadata else {
      completion(nil)
      return
    }
    let title = metadata[MPMediaItemPropertyTitle] as? String
    let artist = metadata[MPMediaItemPropertyArtist] as? String
    let album = metadata[MPMediaItemPropertyAlbumTitle] as? String
    let durationSeconds = metadata[MPMediaItemPropertyPlaybackDuration] as? Double
    let elapsedSeconds = metadata[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double ?? 0
    let playbackRate = metadata[MPNowPlayingInfoPropertyPlaybackRate] as? Double ?? 0
    let playbackState = playbackRate > 0 ? "playing" : (elapsedSeconds > 0 ? "paused" : "stopped")
    let appId = "system.nowplaying"
    let appName = "Now Playing"

    if title == nil && artist == nil && album == nil && playbackState == "stopped" {
      completion(nil)
      return
    }

    let playbackId = [
      appId,
      title ?? "unknown",
      artist ?? "",
    ].joined(separator: ":")

    completion(
      MediaPlaybackSnapshot(
        playbackId: playbackId,
        sourcePlatform: "macos",
        appId: appId,
        appName: appName,
        title: title,
        artist: artist,
        album: album,
        playbackState: playbackState,
        positionMs: max(0, Int(elapsedSeconds * 1000)),
        durationMs: durationSeconds == nil ? nil : max(0, Int(durationSeconds! * 1000)),
        canPlay: playbackState != "playing",
        canPause: playbackState == "playing",
        canSkipNext: true,
        canSkipPrevious: true,
        canSeek: durationSeconds != nil && durationSeconds! > 0,
        updatedAt: ISO8601DateFormatter().string(from: Date())
      )
    )
  }

  func performAction(action: String, positionMs: Int?) -> [String: Any] {
    return [
      "success": false,
      "failureReason": "CapabilityUnavailable",
      "message": "macOS media control bridge is not implemented on this build path.",
    ]
  }
}
