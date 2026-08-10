import Foundation
import Network

public typealias RiftNetworkMonitorCallback = @convention(c) (UnsafeMutableRawPointer?) -> Void

private var monitor: NWPathMonitor?
private var callback: RiftNetworkMonitorCallback?
private var callbackContext: UnsafeMutableRawPointer?
private var activeCallbacks = 0
private let monitorQueue = DispatchQueue(label: "com.rift.daemon.network-monitor")
private let monitorState = NSCondition()

private func invokeCallback() {
    monitorState.lock()
    guard let callback, let callbackContext else {
        monitorState.unlock()
        return
    }
    activeCallbacks += 1
    monitorState.unlock()

    callback(callbackContext)

    monitorState.lock()
    activeCallbacks -= 1
    if activeCallbacks == 0 {
        monitorState.broadcast()
    }
    monitorState.unlock()
}

@_cdecl("rift_network_monitor_start")
public func rift_network_monitor_start(
    _ updateCallback: RiftNetworkMonitorCallback?,
    _ context: UnsafeMutableRawPointer?
) -> Int32 {
    guard let updateCallback else {
        return -1
    }

    monitorState.lock()
    defer { monitorState.unlock() }
    guard monitor == nil else {
        return -1
    }

    let pathMonitor = NWPathMonitor()
    callback = updateCallback
    callbackContext = context
    pathMonitor.pathUpdateHandler = { _ in
        invokeCallback()
    }
    pathMonitor.start(queue: monitorQueue)
    monitor = pathMonitor
    return 0
}

@_cdecl("rift_network_monitor_stop")
public func rift_network_monitor_stop() {
    monitorState.lock()
    let pathMonitor = monitor
    monitor = nil
    callback = nil
    callbackContext = nil
    monitorState.unlock()

    pathMonitor?.cancel()

    monitorState.lock()
    while activeCallbacks > 0 {
        monitorState.wait()
    }
    monitorState.unlock()
}
