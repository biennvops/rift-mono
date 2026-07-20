import Foundation

let riftNotificationExtractorMachService = "com.rift.notification-extractor.xpc"

@objc protocol RiftNotificationExtractorXpcProtocol {
    func request(_ request: Data, withReply reply: @escaping (Data) -> Void)
}
