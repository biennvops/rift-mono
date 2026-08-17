import Foundation

#if RIFT_PRIVATE_API && RIFT_PRIVATE_NOTIFICATION_ACTIONS
import Darwin
import ObjectiveC
import Security
#endif

struct MacOSNotificationActionBackendStatus {
    let backend: String
    let available: Bool
    let canEnumerate: Bool
    let canDismiss: Bool
    let reason: String?

    var jsonObject: [String: Any] {
        var object: [String: Any] = [
            "backend": backend,
            "available": available,
            "canEnumerate": canEnumerate,
            "canDismiss": canDismiss
        ]
        if let reason {
            object["reason"] = reason
        }
        return object
    }
}

struct MacOSNotificationActionCapabilities {
    let backend: String
    let canDismiss: Bool
    let canOpen: Bool
    let reason: String?

    var jsonObject: [String: Any] {
        var object: [String: Any] = [
            "backend": backend,
            "canDismiss": canDismiss,
            "canOpen": canOpen
        ]
        if let reason {
            object["reason"] = reason
        }
        return object
    }
}

struct MacOSNotificationDismissResult {
    let backend: String
    let success: Bool
    let reason: String

    var jsonObject: [String: Any] {
        [
            "backend": backend,
            "success": success,
            "reason": reason
        ]
    }
}

protocol MacOSNotificationActionBackend {
    func status() -> MacOSNotificationActionBackendStatus

    func capabilities(
        notificationId: String,
        packageName: String
    ) -> MacOSNotificationActionCapabilities

    func dismiss(
        notificationId: String,
        packageName: String
    ) -> MacOSNotificationDismissResult
}

func makeMacOSNotificationActionBackend() -> any MacOSNotificationActionBackend {
#if RIFT_PRIVATE_API && RIFT_PRIVATE_NOTIFICATION_ACTIONS
    PrivateMacOSNotificationActionBackend()
#else
    NotCompiledMacOSNotificationActionBackend()
#endif
}

#if RIFT_PRIVATE_API && RIFT_PRIVATE_NOTIFICATION_ACTIONS

private let privateNotificationActionsBuildSentinel = "RIFT_PRIVATE_NOTIFICATION_ACTIONS_V1"

private final class PrivateMacOSNotificationActionBackend: MacOSNotificationActionBackend {
    private static let notificationCenterEntitlements = [
        "com.apple.private.notificationcenter",
        "com.apple.private.notificationcenter-system",
        "com.apple.private.notificationcenter-tester",
        "com.apple.private.notificationcenter-webcenter"
    ]

    private let backendStatus: MacOSNotificationActionBackendStatus

    init() {
        _ = privateNotificationActionsBuildSentinel
        backendStatus = Self.probe()
    }

    func status() -> MacOSNotificationActionBackendStatus {
        backendStatus
    }

    func capabilities(
        notificationId: String,
        packageName: String
    ) -> MacOSNotificationActionCapabilities {
        MacOSNotificationActionCapabilities(
            backend: "private",
            canDismiss: false,
            canOpen: false,
            reason: backendStatus.reason ?? "backendUnavailable")
    }

    func dismiss(
        notificationId: String,
        packageName: String
    ) -> MacOSNotificationDismissResult {
        MacOSNotificationDismissResult(
            backend: "private",
            success: false,
            reason: backendStatus.reason ?? "backendUnavailable")
    }

    private static func probe() -> MacOSNotificationActionBackendStatus {
        guard
            dlopen(
                "/System/Library/PrivateFrameworks/UserNotificationsCore.framework/UserNotificationsCore",
                RTLD_LAZY | RTLD_LOCAL) != nil,
            dlopen(
                "/System/Library/PrivateFrameworks/UserNotificationsKit.framework/UserNotificationsKit",
                RTLD_LAZY | RTLD_LOCAL) != nil
        else {
            return unavailable(reason: "frameworkNotFound")
        }

        guard
            let serviceClientClass = NSClassFromString(
                "UserNotificationsCore.NotificationSystemServiceClient"),
            class_getInstanceMethod(
                serviceClientClass,
                NSSelectorFromString("notificationRecordForIdentifier:bundleIdentifier:")) != nil,
            class_getInstanceMethod(
                serviceClientClass,
                NSSelectorFromString("removeNotificationRecordsForIdentifiers:bundleIdentifier:")) != nil,
            NSClassFromString("NCNotificationRequest") != nil
        else {
            return unavailable(reason: "privateApiMismatch")
        }

        guard notificationCenterEntitlements.contains(where: hasEntitlement) else {
            return unavailable(reason: "privateEntitlementRequired")
        }

        return unavailable(reason: "exactIdentityUnavailable")
    }

    private static func hasEntitlement(_ entitlement: String) -> Bool {
        guard
            let task = SecTaskCreateFromSelf(nil),
            let value = SecTaskCopyValueForEntitlement(task, entitlement as CFString, nil)
        else {
            return false
        }
        return (value as? Bool) == true
    }

    private static func unavailable(reason: String) -> MacOSNotificationActionBackendStatus {
        MacOSNotificationActionBackendStatus(
            backend: "private",
            available: false,
            canEnumerate: false,
            canDismiss: false,
            reason: reason)
    }
}

#else

private final class NotCompiledMacOSNotificationActionBackend: MacOSNotificationActionBackend {
    func status() -> MacOSNotificationActionBackendStatus {
        MacOSNotificationActionBackendStatus(
            backend: "none",
            available: false,
            canEnumerate: false,
            canDismiss: false,
            reason: "notCompiled")
    }

    func capabilities(
        notificationId: String,
        packageName: String
    ) -> MacOSNotificationActionCapabilities {
        MacOSNotificationActionCapabilities(
            backend: "none",
            canDismiss: false,
            canOpen: false,
            reason: "notCompiled")
    }

    func dismiss(
        notificationId: String,
        packageName: String
    ) -> MacOSNotificationDismissResult {
        MacOSNotificationDismissResult(
            backend: "none",
            success: false,
            reason: "notCompiled")
    }
}

#endif
