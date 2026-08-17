#if RIFT_ACCESSIBILITY_NOTIFICATION_ACTIONS

import ApplicationServices
import AppKit
import Foundation

private let notificationCenterBundleIdentifier = "com.apple.notificationcenterui"
private let accessibilityNotificationActionsBuildSentinel = "RIFT_ACCESSIBILITY_NOTIFICATION_ACTIONS_V1"
private let maximumAccessibilityDepth = 24
private let maximumAccessibilityElements = 2_000
private let supportedNotificationSubroles: Set<String> = [
    "AXNotificationCenterAlert",
    "AXNotificationCenterBanner"
]

struct AccessibilityNotificationCandidate {
    let identifier: String
    let subrole: String
    let actions: [String]
    fileprivate let element: AXUIElement?

    init(
        identifier: String,
        subrole: String,
        actions: [String],
        element: AXUIElement? = nil
    ) {
        self.identifier = identifier
        self.subrole = subrole
        self.actions = actions
        self.element = element
    }
}

protocol AccessibilityNotificationRuntime {
    func isTrusted() -> Bool
    func notificationCenterAvailable() -> Bool
    func candidates() throws -> [AccessibilityNotificationCandidate]
    func perform(
        action: String,
        on candidate: AccessibilityNotificationCandidate
    ) throws -> Bool
}

final class AccessibilityMacOSNotificationActionBackend: MacOSNotificationActionBackend {
    private let runtime: any AccessibilityNotificationRuntime
    private let verificationAttempts: Int
    private let verificationPause: (TimeInterval) -> Void
    private let operationLock = NSLock()
    private let candidateCacheLock = NSLock()
    private var cachedCandidates: [AccessibilityNotificationCandidate]?
    private var candidateCacheDate: Date?

    init() {
        _ = accessibilityNotificationActionsBuildSentinel
        runtime = SystemAccessibilityNotificationRuntime()
        verificationAttempts = 20
        verificationPause = Thread.sleep(forTimeInterval:)
    }

    init(
        runtime: any AccessibilityNotificationRuntime,
        verificationAttempts: Int = 20,
        verificationPause: @escaping (TimeInterval) -> Void = Thread.sleep(forTimeInterval:)
    ) {
        self.runtime = runtime
        self.verificationAttempts = verificationAttempts
        self.verificationPause = verificationPause
    }

    func status() -> MacOSNotificationActionBackendStatus {
        guard runtime.isTrusted() else {
            return unavailableStatus(reason: "accessibilityNotTrusted")
        }
        guard runtime.notificationCenterAvailable() else {
            return unavailableStatus(reason: "notificationCenterUnavailable")
        }
        return MacOSNotificationActionBackendStatus(
            backend: "accessibility",
            available: true,
            canEnumerate: true,
            canDismiss: true,
            reason: nil)
    }

    func capabilities(
        notificationId: String,
        packageName: String
    ) -> MacOSNotificationActionCapabilities {
        operationLock.lock()
        defer { operationLock.unlock() }

        let backendStatus = status()
        guard backendStatus.available else {
            return unavailableCapabilities(reason: backendStatus.reason ?? "accessibilityUnavailable")
        }

        do {
            let candidates = try candidatesForCapabilities()
            switch resolve(notificationId: notificationId, in: candidates) {
            case .missing:
                return unavailableCapabilities(reason: "exactIdentityUnavailable")
            case .ambiguous:
                return unavailableCapabilities(reason: "accessibilityIdentityAmbiguous")
            case let .exact(candidate):
                guard individualCloseActions(candidate.actions).count == 1 else {
                    return unavailableCapabilities(reason: "accessibilityNoIndividualCloseAction")
                }
                return MacOSNotificationActionCapabilities(
                    backend: "accessibility",
                    canDismiss: true,
                    canOpen: false,
                    reason: nil)
            }
        } catch {
            return unavailableCapabilities(reason: "accessibilityUnavailable")
        }
    }

    func dismiss(
        notificationId: String,
        packageName: String
    ) -> MacOSNotificationDismissResult {
        operationLock.lock()
        defer { operationLock.unlock() }

        let backendStatus = status()
        guard backendStatus.available else {
            return failedDismiss(reason: backendStatus.reason ?? "accessibilityUnavailable")
        }

        do {
            invalidateCandidateCache()
            let before = try runtime.candidates()
            let candidate: AccessibilityNotificationCandidate
            switch resolve(notificationId: notificationId, in: before) {
            case .missing:
                return failedDismiss(reason: "exactIdentityUnavailable")
            case .ambiguous:
                return failedDismiss(reason: "accessibilityIdentityAmbiguous")
            case let .exact(resolved):
                candidate = resolved
            }

            let closeActions = individualCloseActions(candidate.actions)
            guard closeActions.count == 1 else {
                return failedDismiss(reason: "accessibilityNoIndividualCloseAction")
            }

            let targetIdentifier = canonicalIdentifier(notificationId)
            let siblingIdentifiers = Set(before.compactMap { current -> String? in
                guard
                    supportedNotificationSubroles.contains(current.subrole),
                    let identifier = canonicalIdentifier(current.identifier),
                    identifier != targetIdentifier
                else {
                    return nil
                }
                return identifier
            })

            guard try runtime.perform(action: closeActions[0], on: candidate) else {
                return failedDismiss(reason: "accessibilityActionFailed")
            }
            invalidateCandidateCache()

            for _ in 0 ..< verificationAttempts {
                verificationPause(0.1)
                let after = try runtime.candidates()
                let afterIdentifiers = Set(after.compactMap { current -> String? in
                    guard supportedNotificationSubroles.contains(current.subrole) else {
                        return nil
                    }
                    return canonicalIdentifier(current.identifier)
                })
                if let targetIdentifier,
                   !afterIdentifiers.contains(targetIdentifier),
                   siblingIdentifiers.isSubset(of: afterIdentifiers)
                {
                    return MacOSNotificationDismissResult(
                        backend: "accessibility",
                        success: true,
                        reason: "verified")
                }
            }
            return failedDismiss(reason: "verificationFailed")
        } catch {
            return failedDismiss(reason: "accessibilityUnavailable")
        }
    }

    private func candidatesForCapabilities() throws -> [AccessibilityNotificationCandidate] {
        candidateCacheLock.lock()
        if
            let cachedCandidates,
            let candidateCacheDate,
            Date().timeIntervalSince(candidateCacheDate) < 0.5
        {
            candidateCacheLock.unlock()
            return cachedCandidates
        }
        candidateCacheLock.unlock()

        let candidates = try runtime.candidates()
        candidateCacheLock.lock()
        cachedCandidates = candidates
        candidateCacheDate = Date()
        candidateCacheLock.unlock()
        return candidates
    }

    private func invalidateCandidateCache() {
        candidateCacheLock.lock()
        cachedCandidates = nil
        candidateCacheDate = nil
        candidateCacheLock.unlock()
    }

    private enum Resolution {
        case missing
        case ambiguous
        case exact(AccessibilityNotificationCandidate)
    }

    private func resolve(
        notificationId: String,
        in candidates: [AccessibilityNotificationCandidate]
    ) -> Resolution {
        guard let expectedIdentifier = canonicalIdentifier(notificationId) else {
            return .missing
        }
        let matches = candidates.filter { candidate in
            supportedNotificationSubroles.contains(candidate.subrole)
                && canonicalIdentifier(candidate.identifier) == expectedIdentifier
        }
        if matches.isEmpty {
            return .missing
        }
        if matches.count > 1 {
            return .ambiguous
        }
        return .exact(matches[0])
    }

    private func individualCloseActions(_ actions: [String]) -> [String] {
        actions.filter { action in
            action == "AXDismiss"
                || action == "AXClose"
                || action.split(separator: "\n", maxSplits: 1).first == "Name:Close"
        }
    }

    private func canonicalIdentifier(_ value: String) -> String? {
        UUID(uuidString: value)?.uuidString
    }

    private func unavailableStatus(reason: String) -> MacOSNotificationActionBackendStatus {
        MacOSNotificationActionBackendStatus(
            backend: "accessibility",
            available: false,
            canEnumerate: false,
            canDismiss: false,
            reason: reason)
    }

    private func unavailableCapabilities(reason: String) -> MacOSNotificationActionCapabilities {
        MacOSNotificationActionCapabilities(
            backend: "accessibility",
            canDismiss: false,
            canOpen: false,
            reason: reason)
    }

    private func failedDismiss(reason: String) -> MacOSNotificationDismissResult {
        MacOSNotificationDismissResult(
            backend: "accessibility",
            success: false,
            reason: reason)
    }
}

private final class SystemAccessibilityNotificationRuntime: AccessibilityNotificationRuntime {
    func isTrusted() -> Bool {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func notificationCenterAvailable() -> Bool {
        notificationCenterApplication() != nil
    }

    func candidates() throws -> [AccessibilityNotificationCandidate] {
        guard let application = notificationCenterApplication() else {
            return []
        }

        let root = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.2)
        var result: [AccessibilityNotificationCandidate] = []
        var visited = 0

        func visit(_ element: AXUIElement, depth: Int) {
            guard depth <= maximumAccessibilityDepth, visited < maximumAccessibilityElements else {
                return
            }
            visited += 1

            if
                let identifier = stringAttribute(kAXIdentifierAttribute, from: element),
                let subrole = stringAttribute(kAXSubroleAttribute, from: element),
                supportedNotificationSubroles.contains(subrole)
            {
                result.append(AccessibilityNotificationCandidate(
                    identifier: identifier,
                    subrole: subrole,
                    actions: actionNames(for: element),
                    element: element))
            }

            for child in children(of: element) {
                visit(child, depth: depth + 1)
            }
        }

        visit(root, depth: 0)
        return result
    }

    func perform(
        action: String,
        on candidate: AccessibilityNotificationCandidate
    ) throws -> Bool {
        guard let element = candidate.element else {
            return false
        }
        return AXUIElementPerformAction(element, action as CFString) == .success
    }

    private func notificationCenterApplication() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(
            withBundleIdentifier: notificationCenterBundleIdentifier).first
    }

    private func copyAttribute(
        _ attribute: String,
        from element: AXUIElement
    ) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    private func stringAttribute(
        _ attribute: String,
        from element: AXUIElement
    ) -> String? {
        copyAttribute(attribute, from: element) as? String
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        (copyAttribute(kAXChildrenAttribute, from: element) as? [AXUIElement]) ?? []
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
}

#endif
