import Darwin
import Foundation
import ObjectiveC
import Security

private let frameworkPaths = [
    "/System/Library/PrivateFrameworks/UserNotificationsCore.framework/UserNotificationsCore",
    "/System/Library/PrivateFrameworks/UserNotificationsKit.framework/UserNotificationsKit",
    "/System/Library/PrivateFrameworks/UserNotificationsServices.framework/UserNotificationsServices",
    "/System/Library/PrivateFrameworks/NotificationCenterUI.framework/NotificationCenterUI"
]

private let searchTerms = [
    "notification", "delivered", "record", "identifier", "identity", "source",
    "uuid", "repository", "remove", "withdraw", "dismiss", "clear", "request",
    "section", "bundle"
]

private let entitlementNames = [
    "com.apple.private.notificationcenter",
    "com.apple.private.notificationcenter.server",
    "com.apple.private.notificationcenter-system",
    "com.apple.private.notificationcenter-tester",
    "com.apple.private.notificationcenter-webcenter"
]

private let detailedClassNames: Set<String> = [
    "NCNotificationDispatcher",
    "NCNotificationRequest",
    "UNCNotificationCoreServiceClient",
    "UNCNotificationCoreServiceClientImpl",
    "UNCNotificationSystemServiceConnection",
    "UNSNotificationRecord",
    "UserNotificationsCore.NotificationCoreServiceConnection",
    "UserNotificationsCore.NotificationSystemServiceClient"
]

private let detailedProtocolNames = [
    "UNCNotificationCommonServiceServerProtocol",
    "UNCNotificationCoreServiceClientProtocol",
    "UNCNotificationSystemServiceClientProtocol",
    "UNCNotificationSystemServiceServerProtocol"
]

private func containsSearchTerm(_ value: String) -> Bool {
    let lowercased = value.lowercased()
    return searchTerms.contains { lowercased.contains($0) }
}

private func currentProcessHasEntitlement(_ entitlement: String) -> Bool {
    guard
        let task = SecTaskCreateFromSelf(nil),
        let value = SecTaskCopyValueForEntitlement(task, entitlement as CFString, nil)
    else {
        return false
    }
    return (value as? Bool) == true
}

private func methodDescriptions(
    for cls: AnyClass,
    classMethods: Bool,
    includeAll: Bool
) -> [String] {
    guard let target = classMethods ? object_getClass(cls) : cls else {
        return []
    }
    var count: UInt32 = 0
    guard let methods = class_copyMethodList(target, &count) else {
        return []
    }
    defer { free(methods) }

    return (0 ..< Int(count)).compactMap { index in
        let method = methods[index]
        let selector = NSStringFromSelector(method_getName(method))
        guard includeAll || containsSearchTerm(selector) else {
            return nil
        }
        let encoding = method_getTypeEncoding(method).map(String.init(cString:)) ?? ""
        return "\(classMethods ? "+" : "-") \(selector) \(encoding)"
    }.sorted()
}

private func ivarDescriptions(for cls: AnyClass) -> [String] {
    var count: UInt32 = 0
    guard let ivars = class_copyIvarList(cls, &count) else {
        return []
    }
    defer { free(ivars) }

    return (0 ..< Int(count)).map { index in
        let ivar = ivars[index]
        let name = ivar_getName(ivar).map(String.init(cString:)) ?? ""
        let encoding = ivar_getTypeEncoding(ivar).map(String.init(cString:)) ?? ""
        return "\(name) \(encoding)"
    }.sorted()
}

private func propertyDescriptions(for cls: AnyClass) -> [String] {
    var count: UInt32 = 0
    guard let properties = class_copyPropertyList(cls, &count) else {
        return []
    }
    defer { free(properties) }

    return (0 ..< Int(count)).map { index in
        let property = properties[index]
        let name = String(cString: property_getName(property))
        let attributes = property_getAttributes(property).map(String.init(cString:)) ?? ""
        return "\(name) \(attributes)"
    }.sorted()
}

private func protocolNames(for cls: AnyClass) -> [String] {
    var count: UInt32 = 0
    guard let protocols = class_copyProtocolList(cls, &count) else {
        return []
    }
    let allocation = UnsafeMutableRawPointer(protocols)
    defer { free(allocation) }

    return (0 ..< Int(count))
        .map { String(cString: protocol_getName(protocols[$0])) }
        .sorted()
}

private func methodDescriptions(for proto: Protocol) -> [String] {
    var result: [String] = []
    for required in [true, false] {
        for instance in [true, false] {
            var count: UInt32 = 0
            guard let methods = protocol_copyMethodDescriptionList(
                proto,
                required,
                instance,
                &count)
            else {
                continue
            }
            defer { free(methods) }
            for index in 0 ..< Int(count) {
                let method = methods[index]
                guard let selector = method.name else {
                    continue
                }
                let encoding = method.types.map { String(cString: $0) } ?? ""
                result.append(
                    "\(required ? "required" : "optional") "
                        + "\(instance ? "-" : "+") "
                        + "\(NSStringFromSelector(selector)) \(encoding)")
            }
        }
    }
    return result.sorted()
}

private func allClasses() -> [AnyClass] {
    let count = objc_getClassList(nil, 0)
    guard count > 0 else {
        return []
    }

    let classes = UnsafeMutablePointer<AnyClass?>.allocate(capacity: Int(count))
    defer { classes.deallocate() }
    let loadedCount = objc_getClassList(
        AutoreleasingUnsafeMutablePointer<AnyClass>(classes),
        count)
    return (0 ..< Int(loadedCount)).compactMap { classes[$0] }
}

private func printRuntimeMetadata() {
    for path in frameworkPaths {
        let loaded = dlopen(path, RTLD_LAZY | RTLD_LOCAL) != nil
        print("framework\t\(path)\t\(loaded ? "loaded" : "unavailable")")
    }

    for entitlement in entitlementNames {
        print("entitlement\t\(entitlement)\t\(currentProcessHasEntitlement(entitlement))")
    }

    for cls in allClasses().sorted(by: { NSStringFromClass($0) < NSStringFromClass($1) }) {
        let name = NSStringFromClass(cls)
        let image = class_getImageName(cls).map(String.init(cString:)) ?? ""
        guard
            image.localizedCaseInsensitiveContains("UserNotifications") ||
            image.localizedCaseInsensitiveContains("NotificationCenter")
        else {
            continue
        }

        let includeAll = detailedClassNames.contains(name)
        let methods = methodDescriptions(for: cls, classMethods: false, includeAll: includeAll)
            + methodDescriptions(for: cls, classMethods: true, includeAll: includeAll)
        guard containsSearchTerm(name) || !methods.isEmpty else {
            continue
        }

        print("class\t\(name)\t\(image)")
        if let superclass = class_getSuperclass(cls) {
            print("superclass\t\(name)\t\(NSStringFromClass(superclass))")
        }
        for ivar in ivarDescriptions(for: cls) {
            print("ivar\t\(name)\t\(ivar)")
        }
        for property in propertyDescriptions(for: cls) {
            print("property\t\(name)\t\(property)")
        }
        for protocolName in protocolNames(for: cls) {
            print("protocol\t\(name)\t\(protocolName)")
        }
        for method in methods.sorted() {
            print("method\t\(name)\t\(method)")
        }
    }

    for name in detailedProtocolNames {
        guard let proto = objc_getProtocol(name) else {
            print("runtimeProtocol\t\(name)\tunavailable")
            continue
        }
        print("runtimeProtocol\t\(name)\tavailable")
        for method in methodDescriptions(for: proto) {
            print("protocolMethod\t\(name)\t\(method)")
        }
    }
}

private func printLookup(identifier: String, bundleIdentifier: String) {
    guard
        !identifier.isEmpty,
        bundleIdentifier.hasPrefix("com.rift.notification-research.")
    else {
        print("lookup\trefusingNonResearchIdentity")
        return
    }
    guard dlopen(frameworkPaths[0], RTLD_LAZY | RTLD_LOCAL) != nil else {
        print("lookup\tframeworkUnavailable")
        return
    }
    guard
        let cls = NSClassFromString("UserNotificationsCore.NotificationSystemServiceClient")
            as? NSObject.Type
    else {
        print("lookup\tclassUnavailable")
        return
    }

    let client = cls.init()
    let selector = NSSelectorFromString("notificationRecordForIdentifier:bundleIdentifier:")
    guard client.responds(to: selector) else {
        print("lookup\tselectorUnavailable")
        return
    }
    guard let record = client.perform(
        selector,
        with: identifier as NSString,
        with: bundleIdentifier as NSString)?.takeUnretainedValue() as? NSObject
    else {
        print("lookup\tnotFound\t\(identifier)\t\(bundleIdentifier)")
        return
    }

    print("lookup\tfound\t\(NSStringFromClass(type(of: record)))")
    for property in ["identifier", "description", "dictionaryRepresentation"] {
        let propertySelector = NSSelectorFromString(property)
        guard
            record.responds(to: propertySelector),
            let value = record.perform(propertySelector)?.takeUnretainedValue()
        else {
            continue
        }
        print("property\t\(property)\t\(value)")
    }
}

@main
private struct PrivateRuntimeProbeMain {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "lookup", arguments.count == 3 {
            printLookup(identifier: arguments[1], bundleIdentifier: arguments[2])
            return
        }
        printRuntimeMetadata()
    }
}
