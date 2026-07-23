import CryptoKit
import Foundation
import Security

let riftNotificationExtractorMachService = "com.rift.notification-extractor.xpc"

func riftPeerCodeSigningRequirement(identifier: String) -> String? {
    var code: SecCode?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code else {
        return nil
    }

    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
        return nil
    }

    var signingInformation: CFDictionary?
    guard
        SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &signingInformation) == errSecSuccess,
        let information = signingInformation as? [String: Any]
    else {
        return nil
    }

    if let teamIdentifier = information[kSecCodeInfoTeamIdentifier as String] as? String, !teamIdentifier.isEmpty {
        return "identifier \"\(identifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    }

    guard
        let certificates = information[kSecCodeInfoCertificates as String] as? [SecCertificate],
        let leafCertificate = certificates.first
    else {
        return nil
    }

    let certificateData = SecCertificateCopyData(leafCertificate) as Data
    let certificateHash = Insecure.SHA1.hash(data: certificateData).map { String(format: "%02x", $0) }.joined()
    return "identifier \"\(identifier)\" and certificate leaf = H\"\(certificateHash)\""
}

@objc protocol RiftNotificationExtractorXpcProtocol {
    func request(_ request: Data, withReply reply: @escaping (Data) -> Void)
}
