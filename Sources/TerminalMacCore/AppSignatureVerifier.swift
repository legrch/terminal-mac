import Foundation
import Security

/// Finite signature checks for an independently accepted policy. Tree/hash
/// verification must precede this adapter and be repeated before launch.
/// Signature integrity is not publisher authentication or Gatekeeper approval.
public enum AppSignatureVerifier {
    private static func code(at url: URL) throws -> SecStaticCode {
        var result: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &result) == errSecSuccess,
              let result else { throw AppServiceContract.refuse("APP_SERVICE_APP_IDENTITY") }
        return result
    }

    public static func requireUnsigned(at url: URL) throws {
        let selected = try code(at: url)
        var raw: CFDictionary?
        // Apple's unsigned-code contract is successful information retrieval
        // without the identifier key. An API error is never unsigned evidence.
        guard SecCodeCopySigningInformation(selected, [], &raw) == errSecSuccess,
              let info = raw as? [String: Any], info[kSecCodeInfoIdentifier as String] == nil else {
            throw AppServiceContract.refuse("APP_SERVICE_APP_IDENTITY")
        }
    }

    public static func requireSignature(at url: URL, ignoreResources: Bool = false) throws {
        let selected = try code(at: url)
        var flags = kSecCSStrictValidate | kSecCSCheckAllArchitectures
        if ignoreResources { flags |= kSecCSDoNotValidateResources }
        guard SecStaticCodeCheckValidity(selected, SecCSFlags(rawValue: flags), nil) == errSecSuccess else {
            throw AppServiceContract.refuse("APP_SERVICE_APP_IDENTITY")
        }
    }

    public static func verify(at url: URL, payload: AppServicePayload,
                              policy: AppVerificationPolicy, check: () throws -> Void) throws {
        try policy.validate(payload: payload)
        try check()
        switch policy.outer {
        case "signed-bundle": try requireSignature(at: url)
        case "explicitly-unsigned": try requireUnsigned(at: url)
        default: throw AppServiceContract.refuse("APP_SERVICE_APP_IDENTITY")
        }
        let root = try AppServiceDirectory.open(url)
        for item in policy.checks {
            try check()
            let (parent, leaf) = try root.parent(of: item.path)
            let target = parent.url.appendingPathComponent(leaf)
            switch item.kind {
            case "exact-executable-file":
                guard let data = try parent.read(leaf, limit: 65536),
                      AppServiceDirectory.digest(data) == item.sha256 else {
                    throw AppServiceContract.refuse("APP_SERVICE_APP_IDENTITY")
                }
            case "static-strict-all-architectures": try requireSignature(at: target)
            case "static-strict-all-architectures-no-resources":
                try requireSignature(at: target, ignoreResources: true)
            default: throw AppServiceContract.refuse("APP_SERVICE_APP_IDENTITY")
            }
        }
        try check()
    }
}
