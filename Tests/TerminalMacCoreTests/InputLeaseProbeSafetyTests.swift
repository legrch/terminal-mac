import Foundation
import XCTest
import Darwin
@testable import TerminalMacCore

/// The lease probe is an admission boundary, not an owner-string lookup.
/// Only a validated regular lock and successful nonblocking flock prove FREE.
final class InputLeaseProbeSafetyTests: XCTestCase {
    private func temporary() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lease-probe-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    func testFreeHeldAndReleasedProbeStates() throws {
        let directory = try temporary()
        XCTAssertEqual(try InputLease.probe(directory: directory), .free)
        let lease = try InputLease.acquire(directory: directory, owner: "farol-smoke:synthetic", generation: 9)
        XCTAssertEqual(try InputLease.probe(directory: directory), .held(owner: "farol-smoke:synthetic", generation: 9))
        XCTAssertEqual(InputLease.admission(probe: try InputLease.probe(directory: directory), claimedOwner: "foreign"),
                       .locked(owner: "farol-smoke:synthetic"))
        XCTAssertEqual(InputLease.admission(probe: try InputLease.probe(directory: directory), claimedOwner: "farol-smoke:synthetic"),
                       .allowed, "existing cooperative owner calls remain supported")
        lease.release()
        XCTAssertEqual(try InputLease.probe(directory: directory), .free)
    }

    func testExistingIntegerGenerationsRemainCooperative() throws {
        for generation in [0, -1] {
            let directory = try temporary()
            let lease = try InputLease.acquire(directory: directory, owner: "synthetic", generation: generation)
            defer { lease.release() }
            let state = try InputLease.probe(directory: directory)
            XCTAssertEqual(state, .held(owner: "synthetic", generation: generation))
            XCTAssertEqual(InputLease.admission(probe: state, claimedOwner: "synthetic"), .allowed)
        }
    }

    func testContentionWithMissingCorruptOrUnsafeMetadataNeverAdmitsUnknown() throws {
        let directory = try temporary()
        let lease = try InputLease.acquire(directory: directory, owner: "farol-smoke:synthetic", generation: 5)
        defer { lease.release() }
        let metadata = directory.appendingPathComponent(InputLease.metadataName)
        try FileManager.default.removeItem(at: metadata)
        func expectUnknown() throws {
            let observed = try InputLease.probe(directory: directory)
            XCTAssertEqual(observed, .heldUnknown)
            XCTAssertEqual(InputLease.admission(probe: observed, claimedOwner: "unknown"), .lockedUnknown)
            XCTAssertEqual(InputLease.admission(probe: observed, claimedOwner: "farol-smoke:synthetic"), .lockedUnknown)
            XCTAssertNotNil(InputLease.nativeWindowDenial(probe: observed, windowOwner: "unknown"))
        }
        try expectUnknown()
        try Data("{not-json".utf8).write(to: metadata)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metadata.path)
        try expectUnknown()
        // Even correctly shaped metadata in a group-readable file is not trusted.
        let validButPublic = InputLease.Metadata(schema: InputLease.schema, owner: "farol-smoke:synthetic",
                                                 generation: 5, acquiredAt: 1)
        try JSONEncoder().encode(validButPublic).write(to: metadata, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: metadata.path)
        try expectUnknown()
        try FileManager.default.removeItem(at: metadata)
        let target = directory.appendingPathComponent("synthetic-target")
        try Data("not a valid lease".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: metadata, withDestinationURL: target)
        try expectUnknown()
        try FileManager.default.removeItem(at: metadata)
        try FileManager.default.linkItem(at: target, to: metadata)
        try expectUnknown()
        try FileManager.default.removeItem(at: metadata)
        XCTAssertEqual(mkfifo(metadata.path, 0o600), 0)
        // This must not block waiting for a FIFO writer.
        try expectUnknown()
        try FileManager.default.removeItem(at: metadata)
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: false)
        try expectUnknown()
        try FileManager.default.removeItem(at: metadata)
    }

    func testUnsafeLockEntriesRefuseWithoutBecomingFree() throws {
        for kind in ["directory", "symlink", "fifo", "hardlink", "public"] {
            let directory = try temporary()
            let lock = directory.appendingPathComponent(InputLease.lockName)
            let target = directory.appendingPathComponent("synthetic-owned-target")
            switch kind {
            case "directory": try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: false)
            case "symlink":
                try Data().write(to: target)
                try FileManager.default.createSymbolicLink(at: lock, withDestinationURL: target)
            case "fifo": XCTAssertEqual(mkfifo(lock.path, 0o600), 0)
            case "hardlink":
                try Data().write(to: target)
                try FileManager.default.linkItem(at: target, to: lock)
            case "public":
                try Data().write(to: lock)
                try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: lock.path)
            default: XCTFail("unexpected case")
            }
            XCTAssertThrowsError(try InputLease.probe(directory: directory), kind)
            XCTAssertThrowsError(try InputLease.acquire(directory: directory, owner: "synthetic", generation: 1), kind)
            if kind == "symlink" || kind == "hardlink" {
                XCTAssertEqual(try Data(contentsOf: target), Data(), "unsafe probe never changes the linked target")
            }
        }
    }

    func testUnexpectedOpenAndFlockFailuresAreErrorsNotFreeOrContention() throws {
        let directory = try temporary()
        let malformedParent = directory.appendingPathComponent("regular-not-directory")
        try Data().write(to: malformedParent)
        XCTAssertThrowsError(try InputLease.probe(directory: malformedParent))
        XCTAssertThrowsError(try InputLease.probe(directory: directory, attemptLock: { _ in
            errno = EIO
            return -1
        })) { error in
            XCTAssertTrue(error.localizedDescription.contains("Cannot inspect input lease"))
        }
        XCTAssertEqual(try InputLease.probe(directory: directory, attemptLock: { _ in
            errno = EWOULDBLOCK
            return -1
        }), .heldUnknown, "contention without authenticated metadata is not a known owner")
    }

    func testInvalidOwnerMetadataNeverBecomesANamedHolder() throws {
        let directory = try temporary()
        let lease = try InputLease.acquire(directory: directory, owner: "owner-A", generation: 4)
        defer { lease.release() }
        let metadata = directory.appendingPathComponent(InputLease.metadataName)
        let cases = [
            #"{"schema":"terminal-mac.input-lease/1","owner":"unknown/bypass","generation":4,"acquiredAt":1}"#,
            #"{"schema":"terminal-mac.input-lease/1","owner":"unknown","generation":"not-an-integer","acquiredAt":1}"#,
            #"{"schema":"foreign","owner":"unknown","generation":4,"acquiredAt":1}"#,
        ]
        for item in cases {
            try Data(item.utf8).write(to: metadata)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metadata.path)
            XCTAssertEqual(try InputLease.probe(directory: directory), .heldUnknown)
            XCTAssertEqual(InputLease.admission(probe: try InputLease.probe(directory: directory), claimedOwner: "unknown"), .lockedUnknown)
        }
    }
}
