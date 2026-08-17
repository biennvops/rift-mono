import ApplicationServices
import AppKit
import CryptoKit
import Foundation

private let notificationCenterBundleIdentifier = "com.apple.notificationcenterui"
private let userNotificationCenterBundleIdentifier = "com.apple.UserNotificationCenter"
private let maximumDepth = 24
private let maximumElements = 2_000
private let semanticAttributes = [
    kAXRoleAttribute,
    kAXSubroleAttribute,
    kAXIdentifierAttribute,
    kAXTitleAttribute,
    kAXDescriptionAttribute,
    kAXHelpAttribute,
    kAXValueAttribute,
    kAXRoleDescriptionAttribute
]

private struct ElementSnapshot {
    let path: String
    let values: [String: String]
    let rawValues: [String: String]
    let actions: [String]

    func contains(marker: String) -> Bool {
        rawValues.values.contains { $0.contains(marker) }
    }
}

private func accessibilityTrusted(prompt: Bool) -> Bool {
    let options = [
        kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt
    ] as CFDictionary
    return AXIsProcessTrustedWithOptions(options)
}

private func copyAttribute(_ attribute: String, from element: AXUIElement) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
        return nil
    }
    return value
}

private func stringValue(_ value: CFTypeRef?) -> String? {
    if let value = value as? String {
        return value
    }
    if let value = value as? NSNumber {
        return value.stringValue
    }
    return nil
}

private func actionNames(for element: AXUIElement) -> [String] {
    var names: CFArray?
    guard
        AXUIElementCopyActionNames(element, &names) == .success,
        let names = names as? [String]
    else {
        return []
    }
    return names.sorted()
}

private func children(of element: AXUIElement) -> [AXUIElement] {
    (copyAttribute(kAXChildrenAttribute, from: element) as? [AXUIElement]) ?? []
}

private func snapshots(
    from root: AXUIElement,
    marker: String,
    includeValues: Bool
) -> [(AXUIElement, ElementSnapshot)] {
    var result: [(AXUIElement, ElementSnapshot)] = []

    func visit(_ element: AXUIElement, path: String, depth: Int) {
        guard depth <= maximumDepth, result.count < maximumElements else {
            return
        }

        var values: [String: String] = [:]
        var rawValues: [String: String] = [:]
        for attribute in semanticAttributes {
            guard let value = stringValue(copyAttribute(attribute, from: element)) else {
                continue
            }
            rawValues[attribute] = value
            let isStructural = attribute == kAXRoleAttribute
                || attribute == kAXSubroleAttribute
                || attribute == kAXRoleDescriptionAttribute
            values[attribute] = includeValues || isStructural || value.contains(marker)
                ? value
                : redacted(value)
        }
        result.append((element, ElementSnapshot(
            path: path,
            values: values,
            rawValues: rawValues,
            actions: actionNames(for: element))))

        for (index, child) in children(of: element).enumerated() {
            visit(child, path: "\(path).\(index)", depth: depth + 1)
        }
    }

    visit(root, path: "0", depth: 0)
    return result
}

private func redacted(_ value: String) -> String {
    let digest = SHA256.hash(data: Data(value.utf8))
        .prefix(4)
        .map { String(format: "%02x", $0) }
        .joined()
    return "<redacted:length=\(value.count):sha256=\(digest)>"
}

private func runningApplication(bundleIdentifier: String) -> NSRunningApplication? {
    NSRunningApplication.runningApplications(
        withBundleIdentifier: bundleIdentifier).first
}

private func printSnapshot(_ snapshot: ElementSnapshot) {
    let values = snapshot.values
        .sorted(by: { $0.key < $1.key })
        .map { "\($0.key)=\($0.value.debugDescription)" }
        .joined(separator: "\t")
    let actions = snapshot.actions.joined(separator: ",")
    print("element\t\(snapshot.path)\tactions=\(actions)\t\(values)")
}

private func runDump(
    marker: String,
    includeValues: Bool,
    bundleIdentifier: String
) -> Int32 {
    guard accessibilityTrusted(prompt: false) else {
        fputs("notTrusted\n", stderr)
        return 2
    }
    guard let application = runningApplication(bundleIdentifier: bundleIdentifier) else {
        fputs("notificationCenterUnavailable\n", stderr)
        return 3
    }

    let root = AXUIElementCreateApplication(application.processIdentifier)
    let result = snapshots(from: root, marker: marker, includeValues: includeValues)
    for (_, snapshot) in result {
        printSnapshot(snapshot)
    }
    print("summary\telements=\(result.count)\tmarkerMatches=\(result.filter { $0.1.contains(marker: marker) }.count)")
    return 0
}

private func runClose(
    marker: String,
    identifier: String,
    siblingIdentifier: String?,
    bundleIdentifier: String
) -> Int32 {
    guard marker.hasPrefix("RIFT-RESEARCH-") else {
        fputs("refusing non-research marker\n", stderr)
        return 2
    }
    guard let expectedIdentifier = UUID(uuidString: identifier)?.uuidString else {
        fputs("invalidIdentifier\n", stderr)
        return 2
    }
    guard accessibilityTrusted(prompt: false) else {
        fputs("notTrusted\n", stderr)
        return 3
    }
    guard let application = runningApplication(bundleIdentifier: bundleIdentifier) else {
        fputs("notificationCenterUnavailable\n", stderr)
        return 4
    }

    func hasIdentifier(_ snapshot: ElementSnapshot, _ expected: String) -> Bool {
        snapshot.rawValues[kAXIdentifierAttribute]?.caseInsensitiveCompare(expected) == .orderedSame
    }

    let root = AXUIElementCreateApplication(application.processIdentifier)
    let before = snapshots(from: root, marker: marker, includeValues: false)
    let matches = before.filter {
        hasIdentifier($0.1, expectedIdentifier) && $0.1.contains(marker: marker)
    }
    guard matches.count == 1 else {
        fputs(matches.isEmpty ? "unresolvable\n" : "ambiguous\n", stderr)
        return 5
    }

    let candidate = matches[0]
    let supportedSubroles = ["AXNotificationCenterAlert", "AXNotificationCenterBanner"]
    guard
        let subrole = candidate.1.rawValues[kAXSubroleAttribute],
        supportedSubroles.contains(subrole)
    else {
        fputs("unsupportedNotificationRole\n", stderr)
        return 6
    }
    let closeActions = candidate.1.actions.filter { action in
        action == "AXDismiss"
            || action == "AXClose"
            || action.split(separator: "\n", maxSplits: 1).first == "Name:Close"
    }
    guard closeActions.count == 1 else {
        fputs("individualCloseUnavailable\n", stderr)
        return 6
    }

    let expectedSiblingIdentifier = siblingIdentifier.flatMap { UUID(uuidString: $0)?.uuidString }
    let siblingCountBefore = expectedSiblingIdentifier.map { sibling in
        before.filter { hasIdentifier($0.1, sibling) }.count
    }
    let visibleSiblingIdentifiers = Set(before.compactMap { _, snapshot -> String? in
        guard
            let subrole = snapshot.rawValues[kAXSubroleAttribute],
            supportedSubroles.contains(subrole),
            let rawIdentifier = snapshot.rawValues[kAXIdentifierAttribute],
            let identifier = UUID(uuidString: rawIdentifier)?.uuidString,
            identifier != expectedIdentifier
        else {
            return nil
        }
        return identifier
    })
    guard AXUIElementPerformAction(candidate.0, closeActions[0] as CFString) == .success else {
        fputs("actionFailed\n", stderr)
        return 7
    }

    let deadline = Date().addingTimeInterval(2)
    repeat {
        let after = snapshots(from: root, marker: marker, includeValues: false)
        let targetCount = after.filter { hasIdentifier($0.1, expectedIdentifier) }.count
        let siblingCount = expectedSiblingIdentifier.map { sibling in
            after.filter { hasIdentifier($0.1, sibling) }.count
        }
        let afterIdentifiers = Set(after.compactMap { _, snapshot -> String? in
            guard
                let subrole = snapshot.rawValues[kAXSubroleAttribute],
                supportedSubroles.contains(subrole),
                let rawIdentifier = snapshot.rawValues[kAXIdentifierAttribute]
            else {
                return nil
            }
            return UUID(uuidString: rawIdentifier)?.uuidString
        })
        if targetCount == 0,
           siblingCount == siblingCountBefore,
           visibleSiblingIdentifiers.isSubset(of: afterIdentifiers)
        {
            print("targetDisappeared")
            return 0
        }
        Thread.sleep(forTimeInterval: 0.1)
    } while Date() < deadline

    fputs("verificationFailed\n", stderr)
    return 8
}

private func argument(after name: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else {
        return nil
    }
    return arguments[index + 1]
}

private func configureOutput(arguments: [String]) {
    guard let path = argument(after: "--output", in: arguments) else {
        return
    }
    let url = URL(fileURLWithPath: path).standardizedFileURL
    guard
        url.deletingLastPathComponent().path == "/tmp",
        url.lastPathComponent.hasPrefix("rift-ax-")
    else {
        fputs("--output must name a /tmp/rift-ax-* file\n", stderr)
        exit(64)
    }
    guard
        freopen(url.path, "w", stdout) != nil,
        freopen(url.path, "a", stderr) != nil
    else {
        exit(74)
    }
}

@main
private struct AccessibilityProbeMain {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        configureOutput(arguments: arguments)
        let targetBundleIdentifier = arguments.contains("--banner-process")
            ? userNotificationCenterBundleIdentifier
            : notificationCenterBundleIdentifier
        guard let command = arguments.first else {
            fputs("usage: status [--prompt] [--output PATH] | dump --marker VALUE [--banner-process] [--output PATH] | close --marker VALUE --identifier UUID [--banner-process] [--sibling-identifier UUID] [--output PATH]\n", stderr)
            exit(64)
        }

        switch command {
        case "status":
            print(accessibilityTrusted(prompt: arguments.contains("--prompt")) ? "trusted" : "notTrusted")
        case "dump":
            guard let marker = argument(after: "--marker", in: arguments) else {
                fputs("--marker is required\n", stderr)
                exit(64)
            }
            exit(runDump(
                marker: marker,
                includeValues: false,
                bundleIdentifier: targetBundleIdentifier))
        case "close":
            guard
                let marker = argument(after: "--marker", in: arguments),
                let identifier = argument(after: "--identifier", in: arguments)
            else {
                fputs("--marker and --identifier are required\n", stderr)
                exit(64)
            }
            exit(runClose(
                marker: marker,
                identifier: identifier,
                siblingIdentifier: argument(after: "--sibling-identifier", in: arguments),
                bundleIdentifier: targetBundleIdentifier))
        default:
            fputs("unknown command\n", stderr)
            exit(64)
        }
    }
}
