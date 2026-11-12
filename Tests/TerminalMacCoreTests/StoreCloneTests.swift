import CryptoKit
import Foundation
import XCTest
@testable import TerminalMacCore

// Stopped-machine clone: an independent instance with a fresh identity, a byte-identical disk,
// a provenance receipt, and fail-closed refusals that never leave a partial destination behind.
final class StoreCloneTests: XCTestCase {
    private func store() throws -> (Store, URL) {
        let root = testTemporaryDirectory.appendingPathComponent("clone-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (Store(root: root), root)
    }

    private func machine(_ name: String, in root: URL, disk: Data = Data("disk-sentinel".utf8)) throws {
        let directory = root.appendingPathComponent("machines").appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let machine = Machine(name: name, cpu: 4, memoryGiB: 4, diskGiB: 64, installed: true)
        try JSONEncoder().encode(machine).write(to: directory.appendingPathComponent("machine.json"), options: .atomic)
        try Data("identity-sentinel".utf8).write(to: directory.appendingPathComponent("identity.bin"))
        try disk.write(to: directory.appendingPathComponent("disk.img"))
        try Data("auxiliary-sentinel".utf8).write(to: directory.appendingPathComponent("auxiliary.bin"))
        try Data("hardware-sentinel".utf8).write(to: directory.appendingPathComponent("hardware.bin"))
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func testCloneCreatesAnIndependentMachineWithFreshIdentityAndReceipt() throws {
        let (store, root) = try store()
        try machine("farol-base-1", in: root)
        let identity = Data("fresh-identity-1234".utf8)
        try store.clone(from: "farol-base-1", to: "suite-a", identityData: identity)
        let source = root.appendingPathComponent("machines/farol-base-1")
        let cloned = root.appendingPathComponent("machines/suite-a")
        XCTAssertEqual(try store.load("suite-a").name, "suite-a")
        XCTAssertEqual(try Data(contentsOf: cloned.appendingPathComponent("identity.bin")), identity)
        XCTAssertNotEqual(try Data(contentsOf: cloned.appendingPathComponent("identity.bin")),
                          try Data(contentsOf: source.appendingPathComponent("identity.bin")))
        let machine = try JSONDecoder().decode(Machine.self, from: Data(contentsOf: cloned.appendingPathComponent("machine.json")))
        XCTAssertEqual(machine.name, "suite-a")
        XCTAssertEqual(machine.cpu, 4)
        XCTAssertEqual(machine.installed, true)
        for name in ["machine.json", "identity.bin", "clone.json"] {
            let attributes = try FileManager.default.attributesOfItem(atPath: cloned.appendingPathComponent(name).path)
            XCTAssertEqual(attributes[.posixPermissions] as? NSNumber, NSNumber(value: 0o600), name)
        }
        let receipt = try JSONSerialization.jsonObject(with: Data(contentsOf: cloned.appendingPathComponent("clone.json"))) as! [String: Any]
        XCTAssertEqual(receipt["schema"] as? String, "terminal-mac.clone/1")
        XCTAssertEqual(receipt["from"] as? String, "farol-base-1")
        XCTAssertEqual(receipt["to"] as? String, "suite-a")
        XCTAssertEqual(receipt["identitySha256"] as? String, digest(identity))
        XCTAssertEqual(receipt["diskSha256Source"] as? String, digest(try Data(contentsOf: source.appendingPathComponent("disk.img"))))
        XCTAssertNotNil(receipt["at"] as? Int)
        // The source is untouched and still loads under its own name and identity.
        XCTAssertEqual(try store.load("farol-base-1").name, "farol-base-1")
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("identity.bin")), Data("identity-sentinel".utf8))
    }

    func testCloneCopiesAuxiliaryStateAndDiskBytesExactly() throws {
        let (store, root) = try store()
        // A few MB of an offset-dependent pattern with a marker, so a truncating, reordered or
        // block-shifted copy cannot pass a digest comparison.
        var disk = Data(count: 3 * 1024 * 1024)
        disk.withUnsafeMutableBytes { bytes in
            for offset in 0..<bytes.count { bytes[offset] = UInt8(truncatingIfNeeded: offset >> 8) }
        }
        disk.replaceSubrange(1_234_567..<1_234_578, with: Data("MARKER-9876".utf8))
        try machine("farol-base-1", in: root, disk: disk)
        try store.clone(from: "farol-base-1", to: "suite-a", identityData: Data("fresh-identity".utf8))
        let cloned = root.appendingPathComponent("machines/suite-a")
        for name in ["auxiliary.bin", "hardware.bin", "disk.img"] {
            let sourceData = try Data(contentsOf: root.appendingPathComponent("machines/farol-base-1/\(name)"))
            XCTAssertEqual(try Data(contentsOf: cloned.appendingPathComponent(name)), sourceData, name)
        }
        let sourceDisk = try Data(contentsOf: root.appendingPathComponent("machines/farol-base-1/disk.img"))
        let clonedDisk = try Data(contentsOf: cloned.appendingPathComponent("disk.img"))
        XCTAssertEqual(clonedDisk.count, sourceDisk.count)
        XCTAssertEqual(digest(clonedDisk), digest(sourceDisk))
        let receipt = try JSONSerialization.jsonObject(with: Data(contentsOf: cloned.appendingPathComponent("clone.json"))) as! [String: Any]
        XCTAssertEqual(receipt["diskSha256Source"] as? String, digest(sourceDisk))
    }

    func testOfflineCloneDoesNotChangeTheBaseOrDefaultClone() throws {
        let (store, root) = try store()
        try machine("farol-base-1", in: root)
        let baseConfig = root.appendingPathComponent("machines/farol-base-1/machine.json")
        let original = try Data(contentsOf: baseConfig)
        try store.clone(from: "farol-base-1", to: "closed", identityData: Data("offline-identity".utf8), offline: true)
        try store.clone(from: "farol-base-1", to: "qa", identityData: Data("qa-identity".utf8))
        XCTAssertFalse(try store.load("closed").network)
        XCTAssertTrue(try store.load("qa").network)
        XCTAssertTrue(try store.load("farol-base-1").network)
        XCTAssertEqual(try Data(contentsOf: baseConfig), original)
    }

    func testCloneRefusesCollisionsMissingSourcesSelfClonesAndInvalidNames() throws {
        let (store, root) = try store()
        try machine("pilot", in: root)
        try machine("suite-a", in: root)
        XCTAssertThrowsError(try store.clone(from: "pilot", to: "suite-a", identityData: Data("fresh".utf8)))
        XCTAssertThrowsError(try store.clone(from: "missing", to: "other", identityData: Data("fresh".utf8)))
        XCTAssertThrowsError(try store.clone(from: "pilot", to: "pilot", identityData: Data("fresh".utf8)))
        XCTAssertThrowsError(try store.clone(from: "pilot", to: "suite-a", identityData: Data()))
        for target in ["../escape", "a/b", String(repeating: "x", count: 49)] {
            XCTAssertThrowsError(try store.clone(from: "pilot", to: target, identityData: Data("fresh".utf8)))
        }
        for source in ["../escape", "a/b", String(repeating: "x", count: 49)] {
            XCTAssertThrowsError(try store.clone(from: source, to: "other", identityData: Data("fresh".utf8)))
        }
        // Nothing moved and nothing was created.
        XCTAssertEqual(try store.load("pilot").name, "pilot")
        XCTAssertEqual(try store.load("suite-a").name, "suite-a")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("machines").path).sorted(),
                       ["pilot", "suite-a"])
    }

    func testCloneRefusesARunningMachine() throws {
        let (store, root) = try store()
        try machine("pilot", in: root)
        // Scoped so the lock's deinit releases the flock before the retry.
        do {
            let lock = try FileLock(root.appendingPathComponent("machines/pilot/runtime.lock"))
            try withExtendedLifetime(lock) {
                XCTAssertThrowsError(try store.clone(from: "pilot", to: "suite-a", identityData: Data("fresh".utf8)))
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("machines/suite-a").path))
        try store.clone(from: "pilot", to: "suite-a", identityData: Data("fresh".utf8))
        XCTAssertEqual(try store.load("suite-a").name, "suite-a")
    }

    func testCloneRefusesAHeldInputLease() throws {
        let (store, root) = try store()
        try machine("pilot", in: root)
        let lease = try InputLease.acquire(directory: root.appendingPathComponent("machines/pilot"), owner: "farol-smoke:run-1", generation: 1)
        try withExtendedLifetime(lease) {
            XCTAssertThrowsError(try store.clone(from: "pilot", to: "suite-a", identityData: Data("fresh".utf8))) { error in
                XCTAssertTrue(String(describing: error).contains("farol-smoke:run-1"), "unexpected error: \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("machines/suite-a").path))
    }

    func testFailedCopyCleansUpThePartialDestination() throws {
        let (store, root) = try store()
        try machine("pilot", in: root)
        // A directory named disk.img is not a copyable regular file (clonefile would duplicate
        // the whole tree), so the copy must fail closed.
        let fakeDisk = root.appendingPathComponent("machines/pilot/disk.img")
        try FileManager.default.removeItem(at: fakeDisk)
        try FileManager.default.createDirectory(at: fakeDisk, withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.clone(from: "pilot", to: "suite-a", identityData: Data("fresh".utf8)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("machines/suite-a").path))
    }

    func testBothMachinesLoadIndependentlyAfterClone() throws {
        let (store, root) = try store()
        try machine("farol-base-1", in: root)
        try store.clone(from: "farol-base-1", to: "suite-b", identityData: Data("second-fresh".utf8))
        XCTAssertEqual(try store.load("farol-base-1").name, "farol-base-1")
        XCTAssertEqual(try store.load("suite-b").name, "suite-b")
    }
    func testCloneHoldsRuntimeAndInputCustodyDuringCopy() throws {
        let (store, root) = try store()
        try machine("pilot", in: root)
        let source = try store.directory("pilot")
        var checked = false
        try store.clone(from: "pilot", to: "copy", identityData: Data("fresh".utf8), beforeCopy: {
            checked = true
            XCTAssertThrowsError(try FileLock(source.appendingPathComponent("runtime.lock")))
            XCTAssertThrowsError(try InputLease.acquire(directory: source, owner: "competitor", generation: 2))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("machines/copy/clone.json").path))
        })
        XCTAssertTrue(checked)
        XCTAssertNoThrow(try FileLock(source.appendingPathComponent("runtime.lock")))
        XCTAssertEqual(try InputLease.probe(directory: source), .free)
    }

}
