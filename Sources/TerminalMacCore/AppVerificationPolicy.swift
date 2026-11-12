import Foundation

/// Finite integrity checks. The controller accepts these bytes independently
/// from the payload; this policy is not publisher authentication.
public struct AppVerificationPolicy: Codable {
    public struct Check: Codable {
        public let path: String
        public let kind: String
        public let sha256: String
    }
    public let schema: String
    public let outer: String
    public let checks: [Check]

    public static func decode(_ data: Data) throws -> Self {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["schema", "outer", "checks"],
              let entries = object["checks"] as? [[String: Any]],
              entries.count <= 32,
              entries.allSatisfy({ Set($0.keys) == ["path", "kind", "sha256"] }) else {
            throw AppServiceContract.refuse("APP_SERVICE_APP_IDENTITY")
        }
        return try JSONDecoder().decode(Self.self, from: data)
    }
    public func validate(payload: AppServicePayload) throws {
        try payload.validate()
        guard schema == "terminal-mac.signature-policy/1",
              ["signed-bundle", "explicitly-unsigned"].contains(outer), checks.count <= 32 else {
            throw AppServiceContract.refuse("APP_SERVICE_APP_IDENTITY")
        }
        var seen = Set<String>(), exact = false, signed = false
        for item in checks {
            guard AppServiceContract.path(item.path), seen.insert(item.path.lowercased()).inserted,
                  let node = payload.entries.first(where: { $0.path == item.path }),
                  node.kind == "file", node.mode & 0o111 != 0 else {
                throw AppServiceContract.refuse("APP_SERVICE_APP_IDENTITY")
            }
            switch item.kind {
            case "exact-executable-file":
                guard node.bytes <= 65536, AppServiceContract.hex(item.sha256, count: 64), item.sha256 == node.sha256 else {
                    throw AppServiceContract.refuse("APP_SERVICE_APP_IDENTITY")
                }
                exact = true
            case "static-strict-all-architectures", "static-strict-all-architectures-no-resources":
                guard item.sha256.isEmpty else { throw AppServiceContract.refuse("APP_SERVICE_APP_IDENTITY") }
                signed = true
            default: throw AppServiceContract.refuse("APP_SERVICE_APP_IDENTITY")
            }
        }
        guard outer != "explicitly-unsigned" || (exact && signed) else {
            throw AppServiceContract.refuse("APP_SERVICE_APP_IDENTITY")
        }
    }
}

/// Caller must compare the record bytes with its separately retained acceptance
/// SHA before decoding. Presence in staging is not authorization or publisher proof.
public struct AcceptedApplication: Codable {
    public let schema: String
    public let appName: String
    public let bundleID: String
    public let version: String
    public let artifactSHA256: String
    public let archiveSHA256: String
    public let payloadManifestSHA256: String
    public let signaturePolicySHA256: String
    public let installLocation: String
    public let allowedJourney: String

    public static func decode(_ data: Data) throws -> Self {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["schema", "appName", "bundleID", "version", "artifactSHA256", "archiveSHA256", "payloadManifestSHA256", "signaturePolicySHA256", "installLocation", "allowedJourney"] else {
            throw AppServiceContract.refuse("APP_SERVICE_APP_IDENTITY")
        }
        return try JSONDecoder().decode(Self.self, from: data)
    }
    public func validate(payload: AppServicePayload, manifestDigest: String, policyDigest: String) throws {
        try payload.validate()
        guard schema == "terminal-mac.accepted-application/1",
              appName == payload.appName, bundleID == payload.bundleID, version == payload.version,
              artifactSHA256 == payload.artifactSHA256, archiveSHA256 == payload.archiveSHA256,
              AppServiceContract.hex(payloadManifestSHA256, count: 64), payloadManifestSHA256 == manifestDigest,
              AppServiceContract.hex(signaturePolicySHA256, count: 64), signaturePolicySHA256 == policyDigest,
              installLocation == AppServiceContract.installationLocation, allowedJourney == "installed-lifecycle" else {
            throw AppServiceContract.refuse("APP_SERVICE_APP_IDENTITY")
        }
    }
}
