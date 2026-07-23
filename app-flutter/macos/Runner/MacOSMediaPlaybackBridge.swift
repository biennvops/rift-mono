import AppKit
import Darwin
import FlutterMacOS
import Foundation
import MediaPlayer

final class MacOSMediaPlaybackBridge: NSObject, FlutterStreamHandler {
  private static let methodChannelName = "rift/macos/media_playback"
  private static let eventChannelName = "rift/macos/media_playback_events"

  private let mediaRemote = MediaRemoteController()
  private let workQueue = DispatchQueue(label: "dev.rift.macos.mediaPlayback")
  private var eventSink: FlutterEventSink?
  private var pollTimer: DispatchSourceTimer?
  private var lastSnapshot: MediaPlaybackSnapshot?
  private var lastFingerprint: String?

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
  let artwork: [String: Any]?
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
    if let artwork {
      payload["artwork"] = artwork
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
    let artwork = (metadata[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork)
      .flatMap(Self.encodeArtwork)
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
        artwork: artwork,
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
    guard let command = mediaRemoteCommand(for: action) else {
      return [
        "success": false,
        "failureReason": "CapabilityUnavailable",
        "message": "Unsupported macOS media action.",
      ]
    }

    guard sendMediaRemoteCommand(command) else {
      return [
        "success": false,
        "failureReason": "CapabilityUnavailable",
        "message": "Failed to send the macOS media command.",
      ]
    }

    return ["success": true]
  }

  private static func encodeArtwork(_ artwork: MPMediaItemArtwork) -> [String: Any]? {
    let image = artwork.image(at: NSSize(width: 512, height: 512))
    guard let image,
          let tiffData = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiffData),
          let pngData = bitmap.representation(using: .png, properties: [:])
    else {
      return nil
    }

    return [
      "dataBase64": pngData.base64EncodedString(),
      "mimeType": "image/png",
    ]
  }

  private func mediaRemoteCommand(for action: String) -> Int? {
    switch action {
    case "play":
      return 0
    case "pause":
      return 1
    case "togglePlayPause":
      return 2
    case "next":
      return 4
    case "previous":
      return 5
    default:
      return nil
    }
  }

  private func sendMediaRemoteCommand(_ command: Int) -> Bool {
    let frameworkPath = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
    guard let handle = dlopen(frameworkPath, RTLD_LAZY) else {
      return false
    }
    defer { dlclose(handle) }

    typealias SendCommandFunction = @convention(c) (Int, CFDictionary?) -> Bool
    guard let symbol = dlsym(handle, "MRMediaRemoteSendCommand") else {
      return false
    }

    let function = unsafeBitCast(symbol, to: SendCommandFunction.self)
    return function(command, nil)
  }
}
