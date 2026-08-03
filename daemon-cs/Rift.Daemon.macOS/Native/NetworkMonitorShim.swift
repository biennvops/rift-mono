import Foundation
import Network

public typealias RiftNetworkMonitorCallback = @convention(c) (UnsafeMutableRawPointer?) -> Void

private var monitor: NWPathMonitor?
private var callback: RiftNetworkMonitorCallback?
private var callbackContext: UnsafeMutableRawPointer?
private let monitorQueue = DispatchQueue(label: "com.rift.daemon.network-monitor")

@_cdecl("rift_network_monitor_start")
public func rift_network_monitor_start(
    _ updateCallback: RiftNetworkMonitorCallback?,
    _ context: UnsafeMutableRawPointer?
) -> Int32 {
    guard monitor == nil, let updateCallback else {
        return -1
    }

    let pathMonitor = NWPathMonitor()
    callback = updateCallback
    callbackContext = context
    pathMonitor.pathUpdateHandler = { _ in
        callback?(callbackContext)
    }
    pathMonitor.start(queue: monitorQueue)
    monitor = pathMonitor
    return 0
}

@_cdecl("rift_network_monitor_stop")
public func rift_network_monitor_stop() {
    monitor?.cancel()
    monitor = nil
    callback = nil
    callbackContext = nil
}
