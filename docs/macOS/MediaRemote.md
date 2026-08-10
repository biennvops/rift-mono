# Reading and controlling system media playback on macOS

This document describes the implementation path that works on current macOS, plus the simpler direct approach that worked on older macOS versions.

---

## Summary

### macOS 15.4 and newer
Use:
- `/usr/bin/perl`
- `mediaremote-adapter`
- JSON over stdout/stdin as the integration boundary

Do **not** rely on calling `MRMediaRemoteGetNowPlayingInfo` directly from your app process for metadata reads.

### Older macOS
Direct `MediaRemote.framework` calls from your own process may still work for:
- now-playing metadata
- playback state
- transport control

---

# Current working approach: `/usr/bin/perl` + `mediaremote-adapter`

## Why this is the recommended implementation
On current macOS, direct metadata reads from `MediaRemote.framework` are restricted for normal third-party processes. The working approach is to invoke a helper script through Apple's system Perl binary, which loads a helper framework and returns media information as JSON.

This is the implementation other developers should follow.

---

## What to bundle
Bundle these artifacts with your app:

- `mediaremote-adapter.pl`
- `MediaRemoteAdapter.framework`
- optionally `MediaRemoteAdapterTestClient`

Reference upstream project:
- `https://github.com/ungive/mediaremote-adapter`

---

## Build the adapter

```bash
git clone https://github.com/ungive/mediaremote-adapter.git
cd mediaremote-adapter
mkdir build && cd build
cmake ..
cmake --build . -j4
```

Build outputs:
- `build/MediaRemoteAdapter.framework`
- `build/MediaRemoteAdapterTestClient`
- script at `bin/mediaremote-adapter.pl`

Your app should bundle those files as resources or helper artifacts.

---

## CLI contract

### Read current now-playing info once
```bash
/usr/bin/perl /path/to/mediaremote-adapter.pl /path/to/MediaRemoteAdapter.framework get
```

### Read current now-playing info once, human-readable
```bash
/usr/bin/perl /path/to/mediaremote-adapter.pl /path/to/MediaRemoteAdapter.framework get --human-readable
```

### Stream updates continuously
```bash
/usr/bin/perl /path/to/mediaremote-adapter.pl /path/to/MediaRemoteAdapter.framework stream
```

### Stream updates without diffing
```bash
/usr/bin/perl /path/to/mediaremote-adapter.pl /path/to/MediaRemoteAdapter.framework stream --no-diff
```

### Send media command
```bash
/usr/bin/perl /path/to/mediaremote-adapter.pl /path/to/MediaRemoteAdapter.framework send 2
```

### Verify the adapter still works
```bash
/usr/bin/perl /path/to/mediaremote-adapter.pl /path/to/MediaRemoteAdapter.framework /path/to/MediaRemoteAdapterTestClient test
```

---

## Media command IDs
These are the command IDs used in the direct MediaRemote tests and are the values to pass to `send`:

- `0` = play
- `1` = pause
- `2` = toggle play/pause
- `3` = stop
- `4` = next track
- `5` = previous track

---

# Full Swift implementation for apps

The recommended app integration is:
1. bundle the adapter assets
2. launch `/usr/bin/perl` using `Process`
3. parse JSON output
4. use `send <id>` for transport control
5. use `stream` if you need continuous updates

Below is a complete Swift implementation.

## `MediaRemoteAdapter.swift`

```swift
import Foundation

public struct NowPlayingInfo: Codable {
    public let artist: String?
    public let title: String?
    public let album: String?
    public let duration: Double?
    public let elapsedTime: Double?
    public let elapsedTimeNow: Double?
    public let timestamp: String?
    public let playbackRate: Double?
    public let playing: Bool?
    public let artworkData: String?
    public let artworkMimeType: String?
    public let contentItemIdentifier: String?
    public let processIdentifier: Int?

    public let extra: [String: JSONValue]?

    enum CodingKeys: String, CodingKey {
        case artist
        case title
        case album
        case duration
        case elapsedTime
        case elapsedTimeNow
        case timestamp
        case playbackRate
        case playing
        case artworkData
        case artworkMimeType
        case contentItemIdentifier
        case processIdentifier
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)

        artist = try container.decodeIfPresent(String.self, forKey: .init("artist"))
        title = try container.decodeIfPresent(String.self, forKey: .init("title"))
        album = try container.decodeIfPresent(String.self, forKey: .init("album"))
        duration = try container.decodeIfPresent(Double.self, forKey: .init("duration"))
        elapsedTime = try container.decodeIfPresent(Double.self, forKey: .init("elapsedTime"))
        elapsedTimeNow = try container.decodeIfPresent(Double.self, forKey: .init("elapsedTimeNow"))
        timestamp = try container.decodeIfPresent(String.self, forKey: .init("timestamp"))
        playbackRate = try container.decodeIfPresent(Double.self, forKey: .init("playbackRate"))
        playing = try container.decodeIfPresent(Bool.self, forKey: .init("playing"))
        artworkData = try container.decodeIfPresent(String.self, forKey: .init("artworkData"))
        artworkMimeType = try container.decodeIfPresent(String.self, forKey: .init("artworkMimeType"))
        contentItemIdentifier = try container.decodeIfPresent(String.self, forKey: .init("contentItemIdentifier"))
        processIdentifier = try container.decodeIfPresent(Int.self, forKey: .init("processIdentifier"))

        var extras: [String: JSONValue] = [:]
        for key in container.allKeys {
            switch key.stringValue {
            case "artist", "title", "album", "duration", "elapsedTime", "elapsedTimeNow",
                 "timestamp", "playbackRate", "playing", "artworkData", "artworkMimeType",
                 "contentItemIdentifier", "processIdentifier":
                continue
            default:
                extras[key.stringValue] = try container.decodeIfPresent(JSONValue.self, forKey: key)
            }
        }
        extra = extras.isEmpty ? nil : extras
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicCodingKey.self)
        try container.encodeIfPresent(artist, forKey: .init("artist"))
        try container.encodeIfPresent(title, forKey: .init("title"))
        try container.encodeIfPresent(album, forKey: .init("album"))
        try container.encodeIfPresent(duration, forKey: .init("duration"))
        try container.encodeIfPresent(elapsedTime, forKey: .init("elapsedTime"))
        try container.encodeIfPresent(elapsedTimeNow, forKey: .init("elapsedTimeNow"))
        try container.encodeIfPresent(timestamp, forKey: .init("timestamp"))
        try container.encodeIfPresent(playbackRate, forKey: .init("playbackRate"))
        try container.encodeIfPresent(playing, forKey: .init("playing"))
        try container.encodeIfPresent(artworkData, forKey: .init("artworkData"))
        try container.encodeIfPresent(artworkMimeType, forKey: .init("artworkMimeType"))
        try container.encodeIfPresent(contentItemIdentifier, forKey: .init("contentItemIdentifier"))
        try container.encodeIfPresent(processIdentifier, forKey: .init("processIdentifier"))
        if let extra {
            for (key, value) in extra {
                try container.encode(value, forKey: .init(key))
            }
        }
    }
}

public enum JSONValue: Codable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let v): try container.encode(v)
        case .number(let v): try container.encode(v)
        case .bool(let v): try container.encode(v)
        case .object(let v): try container.encode(v)
        case .array(let v): try container.encode(v)
        case .null: try container.encodeNil()
        }
    }
}

public struct DynamicCodingKey: CodingKey {
    public let stringValue: String
    public let intValue: Int?

    public init(_ string: String) {
        self.stringValue = string
        self.intValue = nil
    }

    public init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    public init?(intValue: Int) {
        self.stringValue = "\(intValue)"
        self.intValue = intValue
    }
}

public enum MediaRemoteCommand: Int {
    case play = 0
    case pause = 1
    case togglePlayPause = 2
    case stop = 3
    case nextTrack = 4
    case previousTrack = 5
}

public enum MediaRemoteAdapterError: Error, CustomStringConvertible {
    case missingScript(URL)
    case missingFramework(URL)
    case invalidOutput(String)
    case processFailed(exitCode: Int32, stderr: String)

    public var description: String {
        switch self {
        case .missingScript(let url):
            return "Missing script at \(url.path)"
        case .missingFramework(let url):
            return "Missing framework at \(url.path)"
        case .invalidOutput(let output):
            return "Invalid adapter output: \(output)"
        case .processFailed(let code, let stderr):
            return "Adapter failed with code \(code): \(stderr)"
        }
    }
}

public final class MediaRemoteAdapter {
    public let scriptURL: URL
    public let frameworkURL: URL
    public let testClientURL: URL?

    private let decoder = JSONDecoder()

    public init(scriptURL: URL, frameworkURL: URL, testClientURL: URL? = nil) {
        self.scriptURL = scriptURL
        self.frameworkURL = frameworkURL
        self.testClientURL = testClientURL
    }

    @discardableResult
    public func test() throws -> Bool {
        guard let testClientURL else {
            throw MediaRemoteAdapterError.invalidOutput("testClientURL is required for test()")
        }
        _ = try run(arguments: [scriptURL.path, frameworkURL.path, testClientURL.path, "test"])
        return true
    }

    public func getNowPlaying(humanReadable: Bool = false, micros: Bool = false, noArtwork: Bool = false) throws -> NowPlayingInfo {
        var args = [scriptURL.path, frameworkURL.path, "get"]
        if humanReadable { args.append("--human-readable") }
        if micros { args.append("--micros") }
        if noArtwork { args.append("--no-artwork") }

        let output = try run(arguments: args)
        guard let data = output.data(using: .utf8) else {
            throw MediaRemoteAdapterError.invalidOutput(output)
        }
        return try decoder.decode(NowPlayingInfo.self, from: data)
    }

    public func send(_ command: MediaRemoteCommand) throws {
        _ = try run(arguments: [scriptURL.path, frameworkURL.path, "send", String(command.rawValue)])
    }

    public func play() throws { try send(.play) }
    public func pause() throws { try send(.pause) }
    public func togglePlayPause() throws { try send(.togglePlayPause) }
    public func nextTrack() throws { try send(.nextTrack) }
    public func previousTrack() throws { try send(.previousTrack) }
    public func stop() throws { try send(.stop) }

    public func makeStreamProcess(noDiff: Bool = false, debounceMilliseconds: Int? = nil, micros: Bool = false, noArtwork: Bool = false) throws -> Process {
        try validatePaths()

        var args = [scriptURL.path, frameworkURL.path, "stream"]
        if noDiff { args.append("--no-diff") }
        if let debounceMilliseconds { args.append("--debounce=\(debounceMilliseconds)") }
        if micros { args.append("--micros") }
        if noArtwork { args.append("--no-artwork") }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = args
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        return process
    }

    private func validatePaths() throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: scriptURL.path) else {
            throw MediaRemoteAdapterError.missingScript(scriptURL)
        }
        guard FileManager.default.fileExists(atPath: frameworkURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw MediaRemoteAdapterError.missingFramework(frameworkURL)
        }
    }

    private func run(arguments: [String]) throws -> String {
        try validatePaths()

        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()

        let out = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let err = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard process.terminationStatus == 0 else {
            throw MediaRemoteAdapterError.processFailed(exitCode: process.terminationStatus, stderr: err)
        }

        return out
    }
}
```

---

## Example usage in Swift

```swift
import Foundation

let resources = URL(fileURLWithPath: "/path/to/bundled/resources")
let adapter = MediaRemoteAdapter(
    scriptURL: resources.appendingPathComponent("mediaremote-adapter.pl"),
    frameworkURL: resources.appendingPathComponent("MediaRemoteAdapter.framework"),
    testClientURL: resources.appendingPathComponent("MediaRemoteAdapterTestClient")
)

do {
    try adapter.test()

    let info = try adapter.getNowPlaying(noArtwork: true)
    print("title=\(info.title ?? "")")
    print("artist=\(info.artist ?? "")")
    print("album=\(info.album ?? "")")
    print("playing=\(info.playing ?? false)")

    try adapter.togglePlayPause()
    try adapter.nextTrack()
} catch {
    print("MediaRemote adapter error: \(error)")
}
```

---

## Example streaming integration

```swift
import Foundation

let resources = URL(fileURLWithPath: "/path/to/bundled/resources")
let adapter = MediaRemoteAdapter(
    scriptURL: resources.appendingPathComponent("mediaremote-adapter.pl"),
    frameworkURL: resources.appendingPathComponent("MediaRemoteAdapter.framework")
)

let process = try adapter.makeStreamProcess(noDiff: true, debounceMilliseconds: 100, noArtwork: true)
let pipe = process.standardOutput as! Pipe

pipe.fileHandleForReading.readabilityHandler = { handle in
    let data = handle.availableData
    guard !data.isEmpty else { return }
    if let text = String(data: data, encoding: .utf8) {
        print("stream chunk:")
        print(text)
    }
}

try process.run()
RunLoop.main.run()
```

For production code, parse each emitted JSON object or line according to the adapter's stream format you choose.

---

# Prior macOS approach: direct `MediaRemote.framework`

This approach is useful as fallback documentation for older macOS versions where direct access still works.

## What it can do
- read now-playing metadata
- read playback state
- send play/pause/next/previous commands

## Objective-C example

```objc
#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>

typedef NS_ENUM(NSInteger, MRPlaybackState) {
    MRPlaybackStateStopped = 0,
    MRPlaybackStatePlaying = 1,
    MRPlaybackStatePaused = 2,
    MRPlaybackStateInterrupted = 3,
};

typedef NS_ENUM(NSInteger, MRMediaRemoteCommand) {
    MRMediaRemoteCommandPlay = 0,
    MRMediaRemoteCommandPause = 1,
    MRMediaRemoteCommandTogglePlayPause = 2,
    MRMediaRemoteCommandStop = 3,
    MRMediaRemoteCommandNextTrack = 4,
    MRMediaRemoteCommandPreviousTrack = 5,
};

extern void MRMediaRemoteGetNowPlayingInfo(dispatch_queue_t queue, void (^block)(CFDictionaryRef information));
extern void MRMediaRemoteGetNowPlayingApplicationPlaybackState(dispatch_queue_t queue, void (^block)(MRPlaybackState state));
extern Boolean MRMediaRemoteSendCommand(MRMediaRemoteCommand command, NSDictionary *userInfo);

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        MRMediaRemoteGetNowPlayingInfo(dispatch_get_main_queue(), ^(CFDictionaryRef information) {
            NSDictionary *dict = information ? CFBridgingRelease(CFRetain(information)) : nil;
            NSLog(@"Now playing: %@", dict);
        });

        MRMediaRemoteGetNowPlayingApplicationPlaybackState(dispatch_get_main_queue(), ^(MRPlaybackState state) {
            NSLog(@"Playback state: %ld", (long)state);
        });

        MRMediaRemoteSendCommand(MRMediaRemoteCommandTogglePlayPause, nil);

        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.0]];
    }
    return 0;
}
```

## Build command

```bash
clang -fobjc-arc -fblocks -framework Foundation -F /System/Library/PrivateFrameworks -framework MediaRemote main.m -o mediaremote-read
```

## Guidance
Use this only for:
- older macOS versions where metadata reads still work
- internal tooling
- experimentation

For current macOS, the supported implementation path for this project should be the Perl adapter approach above.
