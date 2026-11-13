import Foundation
import Darwin
import XCTest
@testable import TerminalMacCore

/// The actual InputLease.acquire entrypoint must refuse predecessor evidence BEFORE writing
/// its own metadata. All files here are disposable synthetic files; no guest/host runtime.
final class InputLeasePredecessorEvidenceTests: XCTestCase {
    private func temporary() throws -> URL {
        let directory = testTemporaryDirectory
            .appendingPathComponent("lease-predecessor-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func priorMetadata(_ directory: URL) throws -> Data {
        let content = Data(#"{"schema":"terminal-mac.input-lease/1","owner":"prior-owner","generation":37,"acquiredAt":123}"#.utf8)
        let path = directory.appendingPathComponent(InputLease.metadataName)
        try content.write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        return content
    }

    private func assertFreeLockAfterRefusal(_ directory: URL, expected: InputLease.Probe = .unresolved,
                                            file: StaticString = #filePath, line: UInt = #line) throws {
        // A successful kernel flock is distinct from application admission. Any retained
        // predecessor record still means UNRESOLVED after the previous owner has exited.
        let fd = open(directory.appendingPathComponent(InputLease.lockName).path,
                      O_RDWR | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(fd, 0, file: file, line: line)
        guard fd >= 0 else { return }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0, file: file, line: line)
        _ = flock(fd, LOCK_UN)
        close(fd)
        XCTAssertEqual(try InputLease.probe(directory: directory), expected, file: file, line: line)
    }

    func testPredecessorUpdateMarkerAndMachineMetadataAreBothPreserved() throws {
        let directory = try temporary()
        let exchange = directory.appendingPathComponent("exchange")
        let box = try Mailbox(exchange, create: true)
        try box.publishLeaseFlag(owner: "prior-owner", ttl: 120, now: Date(timeIntervalSince1970: 1000))
        let marker = exchange.appendingPathComponent(Mailbox.leaseFlagName)
        let markerBefore = try Data(contentsOf: marker)
        let metadataBefore = try priorMetadata(directory)
        XCTAssertThrowsError(try InputLease.acquire(directory: directory, owner: "mcp", generation: 1))
        XCTAssertEqual(try Data(contentsOf: marker), markerBefore, "predecessor's unresolved marker cannot be replaced")
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(InputLease.metadataName)), metadataBefore,
                       "predecessor metadata cannot be replaced or deleted when acquisition fails")
        try assertFreeLockAfterRefusal(directory)
    }

    func testStandaloneMetadataBlocksAcquisitionEvenWithoutMarker() throws {
        let directory = try temporary()
        let before = try priorMetadata(directory)
        XCTAssertThrowsError(try InputLease.acquire(directory: directory, owner: "viewer", generation: 1))
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(InputLease.metadataName)), before)
        try assertFreeLockAfterRefusal(directory)
    }

    func testUnsafeMetadataEntriesBlockWithoutBeingFollowedOrTruncated() throws {
        for kind in ["malformed", "dangling-symlink", "hardlink", "fifo", "directory"] {
            let directory = try temporary()
            let metadata = directory.appendingPathComponent(InputLease.metadataName)
            let target = directory.appendingPathComponent("predecessor-target")
            let sentinel = Data("SYNTHETIC-PREDECESSOR".utf8)
            switch kind {
            case "malformed": try sentinel.write(to: metadata)
            case "dangling-symlink":
                try FileManager.default.createSymbolicLink(at: metadata, withDestinationURL: target)
            case "hardlink":
                try sentinel.write(to: target)
                try FileManager.default.linkItem(at: target, to: metadata)
            case "fifo": XCTAssertEqual(mkfifo(metadata.path, 0o600), 0)
            case "directory": try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: false)
            default: XCTFail("unrecognized fixture")
            }
            XCTAssertThrowsError(try InputLease.acquire(directory: directory, owner: "mcp", generation: 1), kind)
            var retainedInfo = stat()
            XCTAssertEqual(lstat(metadata.path, &retainedInfo), 0, kind)
            if kind == "hardlink" { XCTAssertEqual(try Data(contentsOf: target), sentinel) }
            try assertFreeLockAfterRefusal(directory)
        }
    }

    func testStaleMalformedOrUnsafeMarkerBlocksBeforeMetadataPublication() throws {
        for kind in ["expired", "malformed", "symlink", "hardlink", "fifo", "directory"] {
            let directory = try temporary()
            let exchange = directory.appendingPathComponent("exchange")
            let box = try Mailbox(exchange, create: true)
            let marker = exchange.appendingPathComponent(Mailbox.leaseFlagName)
            let target = exchange.appendingPathComponent("synthetic-target")
            switch kind {
            case "expired": try box.publishLeaseFlag(owner: "prior", ttl: 1, now: Date(timeIntervalSince1970: 1000))
            case "malformed": try box.write(Data("{broken".utf8), named: Mailbox.leaseFlagName)
            case "symlink":
                try Data("predecessor".utf8).write(to: target)
                try FileManager.default.createSymbolicLink(at: marker, withDestinationURL: target)
            case "hardlink":
                try Data("predecessor".utf8).write(to: target)
                try FileManager.default.linkItem(at: target, to: marker)
            case "fifo": XCTAssertEqual(mkfifo(marker.path, 0o600), 0)
            case "directory": try FileManager.default.createDirectory(at: marker, withIntermediateDirectories: false)
            default: XCTFail("unrecognized fixture")
            }
            let dispositionBefore = box.helperUpdateDisposition()
            XCTAssertNotEqual(dispositionBefore, .unmarked)
            XCTAssertThrowsError(try InputLease.acquire(directory: directory, owner: "viewer", generation: 1), kind)
            XCTAssertEqual(box.helperUpdateDisposition(), dispositionBefore)
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(InputLease.metadataName).path),
                           "a prior marker alone must be refused before any machine metadata is published")
            try assertFreeLockAfterRefusal(directory)
        }
    }

    func testExclusivePublicationRefusesARecordCreatedBetweenPreflightAndCreate() throws {
        let directory = try temporary()
        let previous = Data("SYNTHETIC-INTERLEAVED-PREDECESSOR".utf8)
        let metadata = directory.appendingPathComponent(InputLease.metadataName)
        XCTAssertThrowsError(try InputLease.acquire(directory: directory, owner: "viewer", generation: 2,
                                                     beforeMetadataPublication: {
            // Simulate a non-cooperating publisher racing the O_EXCL boundary.
            try previous.write(to: metadata)
        }, beforeDirectorySync: {}))
        XCTAssertEqual(try Data(contentsOf: metadata), previous,
                       "exclusive publication must refuse rather than overwrite an interleaved record")
        try assertFreeLockAfterRefusal(directory)
    }

    func testUncertainPostWriteDirectorySyncRetainsPublishedEvidence() throws {
        let directory = try temporary()
        let metadata = directory.appendingPathComponent(InputLease.metadataName)
        XCTAssertThrowsError(try InputLease.acquire(directory: directory, owner: "mcp", generation: 4,
                                                     beforeMetadataPublication: {},
                                                     beforeDirectorySync: {
            throw Failure("synthetic-directory-fsync-uncertain")
        })) { error in
            XCTAssertTrue(error.localizedDescription.contains("synthetic-directory-fsync-uncertain"))
        }
        let retained = try JSONDecoder().decode(InputLease.Metadata.self, from: Data(contentsOf: metadata))
        XCTAssertEqual(retained.owner, "mcp")
        XCTAssertEqual(retained.generation, 4)
        try assertFreeLockAfterRefusal(directory)
        XCTAssertThrowsError(try InputLease.acquire(directory: directory, owner: "viewer", generation: 5),
                             "a failed sync leaves unresolved predecessor evidence, not authorization")
        XCTAssertEqual(try JSONDecoder().decode(InputLease.Metadata.self, from: Data(contentsOf: metadata)), retained)
    }

    func testCleanAcquisitionAndReleaseAllowNextOwner() throws {
        let directory = try temporary()
        let metadata = directory.appendingPathComponent(InputLease.metadataName)
        let first = try InputLease.acquire(directory: directory, owner: "mcp", generation: 3)
        let exchange = try Mailbox(directory.appendingPathComponent("exchange"))
        try exchange.publishLeaseFlag(owner: "mcp", ttl: 120)
        XCTAssertEqual(try InputLease.probe(directory: directory), .held(owner: "mcp", generation: 3))
        try exchange.releaseLeaseFlag(ownedBy: "mcp")
        first.release()
        XCTAssertFalse(FileManager.default.fileExists(atPath: metadata.path))
        let next = try InputLease.acquire(directory: directory, owner: "viewer", generation: 4)
        XCTAssertEqual(try InputLease.probe(directory: directory), .held(owner: "viewer", generation: 4))
        next.release()
        XCTAssertFalse(FileManager.default.fileExists(atPath: metadata.path))
        try assertFreeLockAfterRefusal(directory, expected: .free)
    }

    func testReleaseNeverUnlinksAnotherRecordThatReplacedOurs() throws {
        let directory = try temporary()
        let metadata = directory.appendingPathComponent(InputLease.metadataName)
        let ours = try InputLease.acquire(directory: directory, owner: "mcp", generation: 3)
        try FileManager.default.removeItem(at: metadata)
        let previous = Data("SYNTHETIC-REPLACEMENT-RECORD".utf8)
        try previous.write(to: metadata)
        ours.release()
        XCTAssertEqual(try Data(contentsOf: metadata), previous)
        try assertFreeLockAfterRefusal(directory)
        XCTAssertThrowsError(try InputLease.acquire(directory: directory, owner: "viewer", generation: 4))
    }

    func testUnknownReleasePreservesOwnEvidenceEvenAfterKernelUnlock() throws {
        let directory = try temporary()
        let metadata = directory.appendingPathComponent(InputLease.metadataName)
        let lease = try InputLease.acquire(directory: directory, owner: "viewer", generation: 5)
        lease.release(preserveMetadata: true)
        let retained = try JSONDecoder().decode(InputLease.Metadata.self, from: Data(contentsOf: metadata))
        XCTAssertEqual(retained.owner, "viewer")
        try assertFreeLockAfterRefusal(directory)
        XCTAssertThrowsError(try InputLease.acquire(directory: directory, owner: "mcp", generation: 6))
        XCTAssertEqual(try JSONDecoder().decode(InputLease.Metadata.self, from: Data(contentsOf: metadata)), retained)
    }

}
