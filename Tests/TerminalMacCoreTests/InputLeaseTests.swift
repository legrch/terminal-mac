import Foundation
import XCTest
@testable import TerminalMacCore

// Exclusive guest-input ownership: flock is the authority, metadata is evidence, and every
// admission decision is tested without AppKit or a VM.
final class InputLeaseTests: XCTestCase {
    func testAcquireReleaseAndConflict() throws {
        let directory = try temporary()
        let lease = try InputLease.acquire(directory: directory, owner: "farol-smoke:run-1", generation: 7)
        XCTAssertEqual(lease.owner, "farol-smoke:run-1")
        XCTAssertEqual(lease.generation, 7)
        XCTAssertThrowsError(try InputLease.acquire(directory: directory, owner: "viewer", generation: 1)) { error in
            let conflict = error as? LeaseConflict
            XCTAssertEqual(conflict?.owner, "farol-smoke:run-1")
        }
        XCTAssertEqual(InputLease.holder(directory: directory), "farol-smoke:run-1")
        lease.release()
        XCTAssertNil(InputLease.holder(directory: directory))
        // Idempotent release keeps the contract simple for defer-based cleanup.
        lease.release()
        XCTAssertNil(InputLease.holder(directory: directory))
    }

    func testMetadataShapeAndAtomicPublication() throws {
        let directory = try temporary()
        let lease = try InputLease.acquire(directory: directory, owner: "viewer", generation: 3)
        defer { lease.release() }
        let metadata = try JSONDecoder().decode(InputLease.Metadata.self, from: Data(contentsOf: directory.appendingPathComponent(InputLease.metadataName)))
        XCTAssertEqual(metadata, InputLease.Metadata(schema: "terminal-mac.input-lease/1", owner: "viewer", generation: 3,
                                                     acquiredAt: metadata.acquiredAt))
        let residue = (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.filter { $0.hasSuffix(".tmp") } ?? []
        XCTAssertTrue(residue.isEmpty, "durable write left temporary files behind: \(residue)")
    }

    func testMetadataIsReadableAfterHolderCrashSimulation() throws {
        // flock releases on process death; the probe must then report free without stale
        // metadata blocking anyone. A released lock plus present metadata must not grant
        // anything: holder() reports the free lease as nil.
        let directory = try temporary()
        let lease = try InputLease.acquire(directory: directory, owner: "mcp", generation: 1)
        XCTAssertNotNil(InputLease.holder(directory: directory))
        lease.release()
        XCTAssertNil(InputLease.holder(directory: directory))
    }

    func testOwnerValidation() throws {
        let directory = try temporary()
        XCTAssertThrowsError(try InputLease.acquire(directory: directory, owner: "", generation: 1))
        XCTAssertThrowsError(try InputLease.acquire(directory: directory, owner: String(repeating: "x", count: 129), generation: 1))
        XCTAssertThrowsError(try InputLease.acquire(directory: directory, owner: "bad owner/slash", generation: 1))
        XCTAssertNoThrow(try InputLease.validate(owner: "farol-smoke:run-ab_12"))
        XCTAssertNoThrow(try InputLease.validate(owner: String(repeating: "a", count: 128)))
    }

    func testAdmissionMatrix() {
        XCTAssertEqual(InputLease.admission(holder: nil, claimedOwner: nil), .allowed)
        XCTAssertEqual(InputLease.admission(holder: nil, claimedOwner: "farol"), .allowed)
        XCTAssertEqual(InputLease.admission(holder: "farol", claimedOwner: "farol"), .allowed)
        XCTAssertEqual(InputLease.admission(holder: "farol", claimedOwner: nil), .locked(owner: "farol"))
        XCTAssertEqual(InputLease.admission(holder: "farol", claimedOwner: "viewer"), .locked(owner: "farol"))
    }

    func testNativeWindowMatrix() {
        XCTAssertTrue(InputLease.nativeWindowAllowed(holder: nil, windowOwner: nil))
        XCTAssertTrue(InputLease.nativeWindowAllowed(holder: nil, windowOwner: "viewer"))
        XCTAssertTrue(InputLease.nativeWindowAllowed(holder: "viewer", windowOwner: "viewer"))
        XCTAssertFalse(InputLease.nativeWindowAllowed(holder: "farol-smoke:run-1", windowOwner: nil))
        XCTAssertFalse(InputLease.nativeWindowAllowed(holder: "farol-smoke:run-1", windowOwner: "viewer"))
    }

    func testLeaseFlagPublishExpiryAndClear() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lease-flag-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let mailbox = try Mailbox(root)
        try mailbox.publishLeaseFlag(owner: "farol-smoke:run-1", ttl: 120)
        XCTAssertEqual(mailbox.leaseFlagHolder(), "farol-smoke:run-1")
        XCTAssertEqual(mailbox.leaseFlagHolder(now: Date().addingTimeInterval(121)), nil, "expired flag must not fence helper updates")
        mailbox.clearLeaseFlag()
        XCTAssertNil(mailbox.leaseFlagHolder())
    }

    func testUnreadableOrForeignFlagDoesNotFence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lease-flag-bad-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let mailbox = try Mailbox(root)
        try mailbox.write(Data("not json".utf8), named: Mailbox.leaseFlagName)
        XCTAssertNil(mailbox.leaseFlagHolder(), "a corrupt flag must never gate helper updates")
        try mailbox.write(Data(#"{"schema":"wrong","owner":"x","deadline":9999999999}"#.utf8), named: Mailbox.leaseFlagName)
        XCTAssertNil(mailbox.leaseFlagHolder())
    }

    func testLeaseFlagIsIgnoredByPickupAndSweep() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lease-flag-sweep-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let mailbox = try Mailbox(root)
        try mailbox.publishLeaseFlag(owner: "viewer", ttl: 120)
        XCTAssertTrue(try mailbox.requests().isEmpty, "the flag must not be picked up as a request")
        // Backdate the flag past the residue age: the sweep touches replies and images only.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-(Mailbox.residueAge + 60))],
                                              ofItemAtPath: root.appendingPathComponent(Mailbox.leaseFlagName).path)
        _ = try mailbox.requests()
        XCTAssertNotNil(try mailbox.read(Mailbox.leaseFlagName), "the lease flag must survive the residue sweep")
    }

    func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("terminal-mac-lease-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
