import Foundation
import XCTest
@testable import TerminalMacCore
@testable import TerminalMac

// Stopped-machine rename: identity and guest data are preserved, the transaction is
// recoverable, and running machines, held leases and collisions refuse safely.
final class StoreRenameTests: XCTestCase {
    private func store() throws -> (Store, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rename-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (Store(root: root), root)
    }

    private func machine(_ name: String, in root: URL) throws {
        let directory = root.appendingPathComponent("machines").appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let machine = Machine(name: name, cpu: 4, memoryGiB: 4, diskGiB: 64, installed: true)
        try JSONEncoder().encode(machine).write(to: directory.appendingPathComponent("machine.json"), options: .atomic)
        try Data("identity-sentinel".utf8).write(to: directory.appendingPathComponent("identity.bin"))
        try Data("disk-sentinel".utf8).write(to: directory.appendingPathComponent("disk.img"))
    }

    func testRenamePreservesIdentityAndRecordsTheMapping() throws {
        let (store, root) = try store()
        try machine("pilot", in: root)
        try store.rename("pilot", to: "farol")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("machines/pilot").path))
        let renamed = root.appendingPathComponent("machines/farol")
        XCTAssertEqual(try store.load("farol").name, "farol")
        XCTAssertEqual(try Data(contentsOf: renamed.appendingPathComponent("identity.bin")), Data("identity-sentinel".utf8))
        XCTAssertEqual(try Data(contentsOf: renamed.appendingPathComponent("disk.img")), Data("disk-sentinel".utf8))
        let receipt = try JSONSerialization.jsonObject(with: Data(contentsOf: renamed.appendingPathComponent("rename.json"))) as! [String: Any]
        XCTAssertEqual(receipt["schema"] as? String, "terminal-mac.rename/1")
        XCTAssertEqual(receipt["from"] as? String, "pilot")
        XCTAssertEqual(receipt["to"] as? String, "farol")
        XCTAssertThrowsError(try store.load("pilot"))
    }

    func testRenameRefusesCollisionsMissingSourcesAndSelfRenames() throws {
        let (store, root) = try store()
        try machine("pilot", in: root)
        try machine("farol", in: root)
        XCTAssertThrowsError(try store.rename("pilot", to: "farol"))
        XCTAssertThrowsError(try store.rename("missing", to: "other"))
        XCTAssertThrowsError(try store.rename("pilot", to: "pilot"))
        // Nothing moved: both machines still load under their own names.
        XCTAssertEqual(try store.load("pilot").name, "pilot")
        XCTAssertEqual(try store.load("farol").name, "farol")
    }

    func testRenameRefusesInvalidNames() throws {
        let (store, root) = try store()
        try machine("pilot", in: root)
        for target in ["../escape", "a/b", String(repeating: "x", count: 49)] {
            XCTAssertThrowsError(try store.rename("pilot", to: target))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("machines/pilot").path))
    }

    func testRenameRefusesARunningMachine() throws {
        let (store, root) = try store()
        try machine("pilot", in: root)
        // Scoped so the lock's deinit releases the flock before the retry.
        do {
            let lock = try FileLock(root.appendingPathComponent("machines/pilot/runtime.lock"))
            try withExtendedLifetime(lock) {
                XCTAssertThrowsError(try store.rename("pilot", to: "farol"))
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("machines/pilot").path))
        try store.rename("pilot", to: "farol")
        XCTAssertEqual(try store.load("farol").name, "farol")
    }

    func testRenameRefusesAHelpInputLease() throws {
        let (store, root) = try store()
        try machine("pilot", in: root)
        let lease = try InputLease.acquire(directory: root.appendingPathComponent("machines/pilot"), owner: "farol-smoke:run-1", generation: 1)
        try withExtendedLifetime(lease) {
            XCTAssertThrowsError(try store.rename("pilot", to: "farol"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("machines/pilot").path))
    }

    @MainActor
    func testInterruptedRenameIsDetectedInsteadOfAdopted() async throws {
        let (store, root) = try store()
        // A half-finished earlier rename left the directory moved but the metadata behind.
        try machine("farol", in: root)
        let stale = root.appendingPathComponent("machines/farol/machine.json")
        var drifted = try JSONDecoder().decode(Machine.self, from: Data(contentsOf: stale))
        drifted.name = "pilot"
        try JSONEncoder().encode(drifted).write(to: stale, options: .atomic)
        XCTAssertThrowsError(try store.load("farol"))
        for command in ["start", "__run"] {
            do {
                try await CLI(store: store).run([command, "farol"])
                XCTFail("Interrupted identity must prevent startup")
            } catch { XCTAssertTrue(error.localizedDescription.contains("Interrupted rename")) }
        }
        XCTAssertThrowsError(try store.rename("farol", to: "final")) { error in
            XCTAssertTrue(String(describing: error).contains("Interrupted rename"),
                          "unexpected error: \(error)")
        }
        // The detected state is preserved for manual recovery, never silently adopted.
        let detected = try JSONDecoder().decode(Machine.self, from: Data(contentsOf: root.appendingPathComponent("machines/farol/machine.json")))
        XCTAssertEqual(detected.name, "pilot")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("machines/final").path))
    }
}
