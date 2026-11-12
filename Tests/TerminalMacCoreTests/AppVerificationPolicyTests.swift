import Foundation
import XCTest
@testable import TerminalMacCore

final class AppVerificationPolicyTests: XCTestCase {
    func fixture() throws -> AppServicePayload { try AppServiceTests().payloadObjects().0 }
    func policy(_ checks: [[String: String]], outer: String = "explicitly-unsigned") throws -> AppVerificationPolicy {
        try AppVerificationPolicy.decode(JSONSerialization.data(withJSONObject: ["schema": "terminal-mac.signature-policy/1", "outer": outer, "checks": checks]))
    }
    func testUnsignedRequiresExplicitExactAndNativeChecks() throws {
        let payload = try fixture(), digest = payload.entries.first(where: { $0.path == "Contents/MacOS/Fixture" })!.sha256
        let exact = ["path": "Contents/MacOS/Fixture", "kind": "exact-executable-file", "sha256": digest]
        // The single fixture executable cannot stand in for two checks on
        // different components. An unsigned bundle must not pass omission.
        for checks in [[], [exact], [["path": "Contents/MacOS/Fixture", "kind": "static-strict-all-architectures", "sha256": ""]], [exact, exact]] {
            XCTAssertThrowsError(try policy(checks).validate(payload: payload))
        }
        XCTAssertNoThrow(try policy([], outer: "signed-bundle").validate(payload: payload))
        XCTAssertThrowsError(try policy([], outer: "skip").validate(payload: payload))
    }
    func testValidUnsignedPolicyAndIndependentAcceptanceDigest() throws {
        let base = try fixture()
        let source = base.entries.first(where: { $0.path == "Contents/MacOS/Fixture" })!
        let engine = AppServicePayload.Entry(path: "Contents/MacOS/Engine", kind: "file", mode: 0o755, bytes: source.bytes,
            sha256: source.sha256, blob: source.blob, target: "")
        let payload = AppServiceTests().changedPayload(base, entries: base.entries + [engine])
        let selected = try policy([
            ["path": source.path, "kind": "exact-executable-file", "sha256": source.sha256],
            ["path": engine.path, "kind": "static-strict-all-architectures", "sha256": ""]])
        try selected.validate(payload: payload)
        try AppServiceTests().temporary { root in
            let stage = try AppServiceDirectory.open(root)
            let policyBytes = try JSONEncoder().encode(selected)
            let manifest = String(repeating: "a", count: 64)
            let accepted = AcceptedApplication(schema: "terminal-mac.accepted-application/1", appName: payload.appName,
                bundleID: payload.bundleID, version: payload.version, artifactSHA256: payload.artifactSHA256,
                archiveSHA256: payload.archiveSHA256, payloadManifestSHA256: manifest,
                signaturePolicySHA256: AppServiceDirectory.digest(policyBytes), installLocation: "guest-applications/1",
                allowedJourney: "installed-lifecycle")
            let bytes = try JSONEncoder().encode(accepted)
            try stage.write(bytes, named: "accepted-application.json", createOnly: true)
            try stage.write(policyBytes, named: "verification-policy.json", createOnly: true)
            let digest = AppServiceDirectory.digest(bytes)
            XCTAssertNoThrow(try AppServiceFiles.acceptance(in: stage, expectedDigest: digest, payload: payload, manifestDigest: manifest))
            XCTAssertThrowsError(try AppServiceFiles.acceptance(in: stage, expectedDigest: manifest, payload: payload, manifestDigest: manifest))
            let swapped = try JSONEncoder().encode(policy([], outer: "signed-bundle"))
            try stage.write(swapped, named: "verification-policy.json")
            XCTAssertThrowsError(try AppServiceFiles.acceptance(in: stage, expectedDigest: digest, payload: payload, manifestDigest: manifest))
        }
    }
    func testRejectsUnknownKeysTraversalNonExecutableAndHashChanges() throws {
        let payload = try fixture()
        for entry in [
            ["path": "../Fixture", "kind": "exact-executable-file", "sha256": String(repeating: "a", count: 64)],
            ["path": "Contents/Info.plist", "kind": "static-strict-all-architectures", "sha256": ""],
            ["path": "Contents/MacOS/Fixture", "kind": "ignore", "sha256": ""],
            ["path": "Contents/MacOS/Fixture", "kind": "exact-executable-file", "sha256": String(repeating: "f", count: 64)]
        ] { XCTAssertThrowsError(try policy([entry], outer: "signed-bundle").validate(payload: payload)) }
        for raw in ["{}", "{\"schema\":\"terminal-mac.signature-policy/1\",\"outer\":\"signed-bundle\",\"checks\":[],\"script\":\"no\"}", "{\"schema\":\"terminal-mac.signature-policy/1\",\"outer\":\"signed-bundle\",\"checks\":[{\"path\":\"x\",\"kind\":\"x\"}]}"] {
            XCTAssertThrowsError(try AppVerificationPolicy.decode(Data(raw.utf8)))
        }
    }
    func testAcceptanceBindsAllPolicyAndIdentityBytes() throws {
        let payload = try fixture(), manifest = String(repeating: "a", count: 64), digest = String(repeating: "b", count: 64)
        let good: [String: String] = ["schema": "terminal-mac.accepted-application/1", "appName": payload.appName, "bundleID": payload.bundleID, "version": payload.version, "artifactSHA256": payload.artifactSHA256, "archiveSHA256": payload.archiveSHA256, "payloadManifestSHA256": manifest, "signaturePolicySHA256": digest, "installLocation": "guest-applications/1", "allowedJourney": "installed-lifecycle"]
        func decode(_ value: [String: String]) throws -> AcceptedApplication { try AcceptedApplication.decode(JSONSerialization.data(withJSONObject: value)) }
        XCTAssertNoThrow(try decode(good).validate(payload: payload, manifestDigest: manifest, policyDigest: digest))
        for key in good.keys {
            var bad = good; bad[key] = "changed"
            XCTAssertThrowsError(try decode(bad).validate(payload: payload, manifestDigest: manifest, policyDigest: digest), key)
            bad = good; bad.removeValue(forKey: key)
            XCTAssertThrowsError(try decode(bad), key)
        }
        var extra = good; extra["environment"] = "untrusted"
        XCTAssertThrowsError(try decode(extra))
    }
}
