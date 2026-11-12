import Foundation
import XCTest
import Darwin
@testable import TerminalMacCore

final class AppServiceTests: XCTestCase {
    let run = "run-" + String(repeating: "a", count: 32)
    let nonce = String(repeating: "b", count: 64)
    let manifest = String(repeating: "c", count: 64)
    let owner = "test-owner"
    let instance = "00000000-0000-4000-8000-000000000001"
    let now = Date(timeIntervalSince1970: 1000)

    func arguments(_ verb: String = "open", sequence: Int = 0, operation: String = UUID().uuidString.lowercased()) -> [String: String] {
        ["serviceCommand": verb, "serviceRun": run, "serviceNonce": nonce,
         "serviceOperation": operation, "serviceSequence": String(sequence),
         "serviceManifest": manifest, "serviceAcceptance": String(repeating: "d", count: 64), "leaseOwner": owner]
    }
    func command(_ verb: String = "open", sequence: Int = 0) throws -> AppServiceCommand {
        try AppServiceCommand(arguments: arguments(verb, sequence: sequence))
    }
    func ready() throws -> AppServiceRecord {
        var record = try AppServiceRecord(open: command(), helperInstance: instance, now: now)
        try record.complete("open")
        return record
    }
    func temporary(_ body: (URL) throws -> Void) throws {
        guard let physical = realpath(FileManager.default.temporaryDirectory.path, nil) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { free(physical) }
        let root = URL(fileURLWithPath: String(cString: physical), isDirectory: true)
            .appendingPathComponent("app-service-unit-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    func testFiniteWireContractRejectsScriptCommandEnvironmentAndPaths() throws {
        let parsed = try command()
        XCTAssertEqual(parsed.runID, run)
        for key in ["script", "command", "argv", "environment", "cwd", "executable"] {
            var value = arguments(); value[key] = "synthetic-untrusted"
            XCTAssertThrowsError(try AppServiceCommand(arguments: value))
        }
        for bad in ["../../qa-3", "run-ABC", "run-" + String(repeating: "a", count: 33)] {
            var value = arguments(); value["serviceRun"] = bad
            XCTAssertThrowsError(try AppServiceCommand(arguments: value))
        }
        for bad in ["-1", "00", "65", "1.0"] {
            var value = arguments(); value["serviceSequence"] = bad
            XCTAssertThrowsError(try AppServiceCommand(arguments: value))
        }
        for bad in ["bash", "serve", "reset", "force-quit", "reconcile"] {
            var value = arguments(); value["serviceCommand"] = bad
            XCTAssertThrowsError(try AppServiceCommand(arguments: value))
        }
    }
    func testExactBindingAndCooperativeCustody() throws {
        var record = try ready()
        var wrong = arguments("install", sequence: 1); wrong["serviceNonce"] = String(repeating: "d", count: 64)
        XCTAssertThrowsError(try record.begin(AppServiceCommand(arguments: wrong), now: now, activeOwner: owner))
        XCTAssertThrowsError(try record.begin(command("install", sequence: 1), now: now, activeOwner: "other-owner"))
        XCTAssertThrowsError(try record.begin(command("install", sequence: 1), now: now, activeOwner: nil))
        XCTAssertEqual(record.phase, "ready")
        XCTAssertEqual(record.sequence, 0)
    }
    func testActualProductionTransitionSequenceAndNormalClose() throws {
        var record = try ready()
        for (index, verb) in ["install", "launch", "activate", "quit", "close"].enumerated() {
            try record.begin(command(verb, sequence: index + 1), now: now, activeOwner: owner)
            XCTAssertEqual(record.phase, "pending")
            XCTAssertEqual(record.pending, verb)
            try record.validate()
            try record.complete(verb, pid: ["launch", "activate"].contains(verb) ? 123 : nil)
            try record.validate()
        }
        XCTAssertEqual(record.phase, "closed")
        XCTAssertNil(record.appPID)
        XCTAssertEqual(record.operations.count, 6)
        XCTAssertThrowsError(try record.begin(command("launch", sequence: 6), now: now, activeOwner: owner))
    }
    func testOutOfOrderDuplicateAndBusyRequestsHaveNoNewEffect() throws {
        var record = try ready()
        XCTAssertThrowsError(try record.begin(command("launch", sequence: 1), now: now, activeOwner: owner))
        XCTAssertThrowsError(try record.begin(command("install", sequence: 2), now: now, activeOwner: owner))
        let install = try command("install", sequence: 1)
        try record.begin(install, now: now, activeOwner: owner)
        XCTAssertThrowsError(try record.begin(command("install", sequence: 2), now: now, activeOwner: owner))
        try record.complete("install")
        var replay = arguments("launch", sequence: 2); replay["serviceOperation"] = install.operationID
        XCTAssertThrowsError(try record.begin(AppServiceCommand(arguments: replay), now: now, activeOwner: owner))
        XCTAssertEqual(record.sequence, 1)
    }
    func testExpiryNeverMeansCompletionButAllowsBoundedOwnedQuit() throws {
        var record = try ready()
        try record.begin(command("install", sequence: 1), now: now, activeOwner: owner)
        try record.complete("install")
        try record.begin(command("launch", sequence: 2), now: now, activeOwner: owner)
        try record.complete("launch", pid: 123)
        let expired = now.addingTimeInterval(AppServiceContract.lifetime + 1)
        XCTAssertThrowsError(try record.begin(command("activate", sequence: 3), now: expired, activeOwner: owner))
        XCTAssertEqual(record.phase, "running")
        try record.begin(command("quit", sequence: 3), now: expired, activeOwner: owner)
        try record.complete("quit")
        try record.begin(command("close", sequence: 4), now: expired, activeOwner: owner)
        try record.complete("close")
        XCTAssertEqual(record.phase, "closed")
    }
    func testUnknownAndPartialPublicationStayUnresolved() throws {
        var record = try ready()
        try record.begin(command("install", sequence: 1), now: now, activeOwner: owner)
        let operation = record.operationID
        record.markUnknown()
        try record.validate()
        XCTAssertEqual(record.operationID, operation)
        XCTAssertEqual(record.phase, "unknown")
        XCTAssertThrowsError(try record.begin(command("close", sequence: 2), now: now, activeOwner: owner))
        XCTAssertThrowsError(try record.complete("install"))
        let restored = try JSONDecoder().decode(AppServiceRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(restored, record)
    }
    func testUpdateGatePreservesPendingReadyMalformedAndMissingRecords() throws {
        try temporary { root in
            XCTAssertFalse(AppServiceFiles.hasUnresolved(in: root))
            let directory = try AppServiceDirectory.open(root, privateDirectory: true)
            let runDirectory = try directory.child(run, create: true, exclusive: true)
            XCTAssertTrue(AppServiceFiles.hasUnresolved(in: root))
            var record = try ready()
            try runDirectory.write(JSONEncoder().encode(record), named: "state.json", createOnly: true)
            XCTAssertTrue(AppServiceFiles.hasUnresolved(in: root))
            try record.begin(command("close", sequence: 1), now: now, activeOwner: owner)
            try record.complete("close")
            try runDirectory.write(JSONEncoder().encode(record), named: "state.json")
            XCTAssertTrue(AppServiceFiles.hasUnresolved(in: root), "closed state without its operation receipt is not completion proof")
            try runDirectory.write(JSONEncoder().encode(record), named: "receipt-" + record.operationID + ".json", createOnly: true)
            XCTAssertFalse(AppServiceFiles.hasUnresolved(in: root))
            try runDirectory.write(Data("malformed".utf8), named: "state.json")
            XCTAssertTrue(AppServiceFiles.hasUnresolved(in: root))
        }
    }
    func testUpdateAndServiceUseTheSameExclusiveKernelLock() throws {
        try temporary { root in
            let directory = try AppServiceDirectory.open(root, privateDirectory: true)
            var held: AppServiceLock? = try directory.lock()
            XCTAssertNotNil(held)
            XCTAssertThrowsError(try directory.lock())
            held = nil
            let next = try directory.lock()
            withExtendedLifetime(next) { XCTAssertFalse(AppServiceFiles.hasUnresolved(in: root)) }
        }
    }

    func payloadObjects() throws -> (AppServicePayload, [String: Data]) {
        let info = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "test.native-service", "CFBundleShortVersionString": "1.0.0", "CFBundleExecutable": "Fixture"], format: .xml, options: 0)
        let program = Data("synthetic-data-not-executed".utf8)
        let blobs = ["blob-" + AppServiceDirectory.digest(info): info,
                     "blob-" + AppServiceDirectory.digest(program): program]
        let entries: [AppServicePayload.Entry] = [
            .init(path: "Contents", kind: "directory", mode: 0o755, bytes: 0, sha256: "", blob: "", target: ""),
            .init(path: "Contents/MacOS", kind: "directory", mode: 0o755, bytes: 0, sha256: "", blob: "", target: ""),
            .init(path: "Contents/Info.plist", kind: "file", mode: 0o644, bytes: info.count, sha256: AppServiceDirectory.digest(info), blob: "blob-" + AppServiceDirectory.digest(info), target: ""),
            .init(path: "Contents/MacOS/Fixture", kind: "file", mode: 0o755, bytes: program.count, sha256: AppServiceDirectory.digest(program), blob: "blob-" + AppServiceDirectory.digest(program), target: "")
        ]
        return (.init(schema: AppServiceContract.payloadVersion, appName: "Fixture.app", bundleID: "test.native-service", version: "1.0.0", artifactSHA256: manifest, archiveSHA256: manifest, entries: entries), blobs)
    }
    func changedPayload(_ base: AppServicePayload, entries: [AppServicePayload.Entry]) -> AppServicePayload {
        .init(schema: base.schema, appName: base.appName, bundleID: base.bundleID, version: base.version,
              artifactSHA256: base.artifactSHA256, archiveSHA256: base.archiveSHA256, entries: entries)
    }
    func testGuestApplicationsTargetIsVersionedAndCreateOnlyInDisposableMirror() throws {
        XCTAssertEqual(AppServiceContract.version, "terminal-mac.app-service/4")
        XCTAssertEqual(AppServiceContract.installationRoot, "/Applications")
        XCTAssertEqual(AppServiceContract.installationLocation, "guest-applications/1")
        // NEVER write the host /Applications in a test. This mirror qualifies
        // the same descriptor-relative exclusive-create installer behavior.
        try temporary { root in
            let sandbox = try AppServiceDirectory.open(root)
            let stage = try sandbox.child("stage", create: true, exclusive: true)
            let guestApplications = try sandbox.child("Applications", create: true, exclusive: true)
            let (payload, blobs) = try payloadObjects()
            XCTAssertNoThrow(try guestApplications.requireAbsent(payload.appName))
            for (name, data) in blobs {
                try stage.write(data, named: name, createOnly: true)
            }
            let installed = try AppServiceFiles.install(payload, from: stage, into: guestApplications, check: {})
            XCTAssertEqual(installed.path, guestApplications.url.appendingPathComponent(payload.appName).path)
            XCTAssertEqual(installed.lastPathComponent, payload.appName)
            try AppServiceFiles.verifyInstalled(payload, in: AppServiceDirectory.open(installed), check: {})
            // An unrelated or predecessor installation cannot be replaced,
            // even if its current bytes happen to match the accepted payload.
            XCTAssertThrowsError(try guestApplications.requireAbsent(payload.appName)) { error in
                XCTAssertEqual((error as? OutcomeFailure)?.message, "APP_SERVICE_INSTALLED_COLLISION")
            }
            XCTAssertThrowsError(try AppServiceFiles.install(payload, from: stage, into: guestApplications, check: {}))
            try AppServiceFiles.verifyInstalled(payload, in: AppServiceDirectory.open(installed), check: {})
            let alias = root.appendingPathComponent("ApplicationsAlias")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: guestApplications.url)
            XCTAssertThrowsError(try AppServiceDirectory.open(alias),
                                 "a symlink installation parent must fail closed")
            let foreign = root.appendingPathComponent("foreign")
            try Data("synthetic foreign file".utf8).write(to: foreign)
            let occupied = guestApplications.url.appendingPathComponent("Occupied.app")
            try FileManager.default.createSymbolicLink(at: occupied, withDestinationURL: foreign)
            XCTAssertThrowsError(try guestApplications.requireAbsent("Occupied.app"),
                                 "even a dangling or foreign symlink is an occupied app name")
            XCTAssertEqual(try Data(contentsOf: foreign), Data("synthetic foreign file".utf8))
        }
    }

    func testRealMaterializerAndFullInstalledTreeVerification() throws {
        try temporary { root in
            let directory = try AppServiceDirectory.open(root)
            let source = try directory.child("stage", create: true)
            let destination = try directory.child("run", create: true)
            let (payload, blobs) = try payloadObjects()
            for (name, data) in blobs { try source.write(data, named: name, createOnly: true) }
            let data = try JSONEncoder().encode(payload)
            try source.write(data, named: "app-payload.json", createOnly: true)
            let (decoded, _) = try AppServiceFiles.payload(in: source, expectedDigest: AppServiceDirectory.digest(data))
            let installed = try AppServiceFiles.install(decoded, from: source, into: destination, check: {})
            let app = try AppServiceDirectory.open(installed)
            try AppServiceFiles.verifyInstalled(decoded, in: app, check: {})
            let binary = installed.appendingPathComponent("Contents/MacOS/Fixture")
            try Data("changed".utf8).write(to: binary)
            XCTAssertThrowsError(try AppServiceFiles.verifyInstalled(decoded, in: app, check: {}))
            XCTAssertThrowsError(try AppServiceFiles.install(decoded, from: source, into: destination, check: {}), "never replace an existing install")
        }
    }
    func testManifestDigestAndClosedShapeAreCheckedBeforeInstall() throws {
        try temporary { root in
            let source = try AppServiceDirectory.open(root)
            let (payload, _) = try payloadObjects()
            let data = try JSONEncoder().encode(payload)
            try source.write(data, named: "app-payload.json", createOnly: true)
            XCTAssertThrowsError(try AppServiceFiles.payload(in: source, expectedDigest: String(repeating: "0", count: 64)))
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            object["script"] = "guest.sh"
            let modified = try JSONSerialization.data(withJSONObject: object)
            try source.write(modified, named: "app-payload.json")
            XCTAssertThrowsError(try AppServiceFiles.payload(in: source, expectedDigest: AppServiceDirectory.digest(modified)))
        }
    }
    func testTraversalAliasAndFileAsParentAreRejected() throws {
        let (payload, _) = try payloadObjects()
        for path in ["../outside", "/absolute", "Contents/../outside", "Contents//file", "Contents\\file", "Contents/file:", "Contents/\nfile"] {
            let bad = AppServicePayload.Entry(path: path, kind: "directory", mode: 0o755, bytes: 0, sha256: "", blob: "", target: "")
            XCTAssertThrowsError(try changedPayload(payload, entries: payload.entries + [bad]).validate())
        }
        let alias = AppServicePayload.Entry(path: "contents", kind: "directory", mode: 0o755, bytes: 0, sha256: "", blob: "", target: "")
        XCTAssertThrowsError(try changedPayload(payload, entries: payload.entries + [alias]).validate())
        let underFile = AppServicePayload.Entry(path: "Contents/Info.plist/child", kind: "directory", mode: 0o755, bytes: 0, sha256: "", blob: "", target: "")
        XCTAssertThrowsError(try changedPayload(payload, entries: payload.entries + [underFile]).validate())
    }
    func testFrameworkSymlinkResolvesThroughIntermediateCurrent() throws {
        let (payload, _) = try payloadObjects()
        func directory(_ path: String) -> AppServicePayload.Entry {
            .init(path: path, kind: "directory", mode: 0o755, bytes: 0, sha256: "", blob: "", target: "")
        }
        func link(_ path: String, _ target: String) -> AppServicePayload.Entry {
            .init(path: path, kind: "symlink", mode: 0o777, bytes: 0, sha256: "", blob: "", target: target)
        }
        let framework = [directory("Contents/Framework"), directory("Contents/Framework/Versions"),
                         directory("Contents/Framework/Versions/A"), directory("Contents/Framework/Versions/A/Resources"),
                         link("Contents/Framework/Versions/Current", "A"),
                         link("Contents/Framework/Resources", "Versions/Current/Resources")]
        XCTAssertNoThrow(try changedPayload(payload, entries: payload.entries + framework).validate())
        let bad = framework.dropLast() + [link("Contents/Framework/Resources", "Versions/Current/Missing")]
        XCTAssertThrowsError(try changedPayload(payload, entries: payload.entries + bad).validate())
    }
    func testSymlinkEscapeAndCyclesAreRefused() throws {
        let (payload, _) = try payloadObjects()
        for target in ["../../outside", "/private/file", "missing", "alias"] {
            let bad = AppServicePayload.Entry(path: "alias", kind: "symlink", mode: 0o777, bytes: 0, sha256: "", blob: "", target: target)
            XCTAssertThrowsError(try changedPayload(payload, entries: payload.entries + [bad]).validate())
        }
        let one = AppServicePayload.Entry(path: "one", kind: "symlink", mode: 0o777, bytes: 0, sha256: "", blob: "", target: "two")
        let two = AppServicePayload.Entry(path: "two", kind: "symlink", mode: 0o777, bytes: 0, sha256: "", blob: "", target: "one")
        XCTAssertThrowsError(try changedPayload(payload, entries: payload.entries + [one, two]).validate())
    }
    func testUnsafeBlobCannotHangOrFollowHostData() throws {
        for kind in ["symlink", "fifo", "hardlink"] {
            try temporary { root in
                let directory = try AppServiceDirectory.open(root)
                let source = try directory.child("stage", create: true)
                let destination = try directory.child("out", create: true)
                let data = Data("not-a-secret".utf8)
                let leaf = "blob-" + AppServiceDirectory.digest(data)
                let original = root.appendingPathComponent("original")
                try data.write(to: original)
                let bad = source.url.appendingPathComponent(leaf)
                switch kind {
                case "symlink": try FileManager.default.createSymbolicLink(at: bad, withDestinationURL: original)
                case "fifo": XCTAssertEqual(mkfifo(bad.path, 0o600), 0)
                default: XCTAssertEqual(link(original.path, bad.path), 0)
                }
                XCTAssertThrowsError(try source.copyBlob(leaf, into: destination, named: "file", bytes: data.count,
                    sha256: AppServiceDirectory.digest(data), mode: 0o600, check: {}))
                XCTAssertEqual(try Data(contentsOf: original), data)
            }
        }
    }
    func testTamperedBlobAndInterruptedInstallLeaveEvidenceNotSuccess() throws {
        try temporary { root in
            let directory = try AppServiceDirectory.open(root)
            let source = try directory.child("stage", create: true)
            let destination = try directory.child("out", create: true)
            let (payload, blobs) = try payloadObjects()
            for (name, data) in blobs { try source.write(data, named: name, createOnly: true) }
            var checks = 0
            XCTAssertThrowsError(try AppServiceFiles.install(payload, from: source, into: destination, check: {
                checks += 1
                if checks == 4 { throw AppServiceContract.refuse("APP_SERVICE_EXPIRED") }
            }))
            XCTAssertTrue(FileManager.default.fileExists(atPath: destination.url.appendingPathComponent(payload.appName).path), "partial owned install is retained, not silently rolled back")
        }
    }
    func testNoFollowReadAndReadOnlyVolumePrecondition() throws {
        try temporary { root in
            let directory = try AppServiceDirectory.open(root)
            XCTAssertThrowsError(try directory.requireReadOnlyVolume(), "ordinary writable fixture is not a readonly guest artifact mount")
            XCTAssertNil(try directory.read("absent.json", limit: 1024))
            let fifo = root.appendingPathComponent("record.json")
            XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
            XCTAssertThrowsError(try directory.read("record.json", limit: 1024))
        }
    }
    func testCLIUsesDistinctWireActionAndDiagnosticAllowlist() throws {
        XCTAssertEqual(try GuestActionTarget(positionals: ["app-service"], explicitName: "fixture").verb, "app-service")
        let value = ActionFailureDiagnostic(error: AppServiceContract.refuse("APP_SERVICE_BINDING"), dispatched: false, phase: "validation")
        XCTAssertEqual(value.outcome, "noEffect")
        XCTAssertEqual(value.reason, "APP_SERVICE_BINDING")
        let privateText = ActionFailureDiagnostic(error: OutcomeFailure("SYNTHETIC_PRIVATE_TOKEN", outcome: .mutationUnknown), dispatched: true, phase: "dispatch")
        XCTAssertEqual(privateText.reason, "UNCLASSIFIED")
    }
}
