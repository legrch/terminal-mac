import Darwin
import Foundation
import XCTest
@testable import TerminalMacCore

final class HelperUpdateDurabilityTests: XCTestCase {
    func testFileAndDirectorySyncFailuresPreventDispatchAndRetainHostCustody() throws {
        for failedSync in [1, 2] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let lease = try InputLease.acquire(directory: root, owner: "cli:test", generation: 1)
            var syncs = 0, dispatched = false
            let box = try Mailbox(root.appendingPathComponent("exchange"), sync: { fd in
                syncs += 1
                if syncs == failedSync { errno = EIO; return -1 }
                return fsync(fd)
            })
            XCTAssertThrowsError(try {
                try box.publishLeaseFlag(owner: lease.owner, ttl: 120)
                dispatched = true
            }())
            XCTAssertFalse(dispatched)
            XCTAssertEqual(syncs, failedSync)
            lease.release(preserveMetadata: true)
            XCTAssertEqual(try InputLease.probe(directory: root), .unresolved)
            XCTAssertThrowsError(try InputLease.acquire(directory: root, owner: "next", generation: 2))
            if failedSync == 2 { XCTAssertFalse(box.helperUpdateDisposition().mayUpdate) }
        }
    }

    func testSuccessfulPublicationSyncsFileThenDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var kinds: [mode_t] = []
        let box = try Mailbox(root, sync: { fd in
            var info = stat()
            guard fstat(fd, &info) == 0 else { return -1 }
            kinds.append(info.st_mode & S_IFMT)
            return fsync(fd)
        })
        try box.publishLeaseFlag(owner: "test", ttl: 120)
        XCTAssertEqual(kinds, [mode_t(S_IFREG), mode_t(S_IFDIR)])
    }
}
