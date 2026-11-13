import Foundation
import Darwin
import XCTest
@testable import TerminalMacCore

/// No guest, clipboard or host update. Exercises the actual Mailbox decision used by GuestRuntime.
final class HelperUpdateCustodyTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1000)

    private func box() throws -> (Mailbox, URL) {
        let directory = testTemporaryDirectory
            .appendingPathComponent("helper-update-custody-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return (try Mailbox(directory), directory)
    }

    func testOnlyAbsentMarkerPermitsBestEffortUpdate() throws {
        let (mailbox, _) = try box()
        XCTAssertEqual(mailbox.helperUpdateDisposition(now: start), .unmarked)
        XCTAssertTrue(mailbox.helperUpdateDisposition(now: start).mayUpdate)
        XCTAssertNoThrow(try mailbox.requireNoOutstandingUpdateMarker(now: start))
    }

    func testFreshAndExpiredMarkerBothDeferEvenWhenLegacyLookupReturnsNil() throws {
        let (mailbox, _) = try box()
        try mailbox.publishLeaseFlag(owner: "mcp", ttl: 120, now: start)
        XCTAssertEqual(mailbox.helperUpdateDisposition(now: start), .active(owner: "mcp"))
        XCTAssertEqual(mailbox.leaseFlagHolder(now: start), "mcp")
        XCTAssertEqual(mailbox.helperUpdateDisposition(now: start.addingTimeInterval(121)), .stale(owner: "mcp"))
        XCTAssertNil(mailbox.leaseFlagHolder(now: start.addingTimeInterval(121)),
                     "legacy display-only lookup is not update admission")
        XCTAssertFalse(mailbox.helperUpdateDisposition(now: start.addingTimeInterval(121)).mayUpdate)
        XCTAssertThrowsError(try mailbox.requireNoOutstandingUpdateMarker(now: start.addingTimeInterval(121)))
    }

    func testMalformedOrUnconfirmedMarkerDefersWithoutClearingEvidence() throws {
        let (mailbox, directory) = try box()
        let name = Mailbox.leaseFlagName
        let scenarios = [
            "not json",
            #"{"schema":"wrong","owner":"mcp","deadline":3000}"#,
            #"{"schema":"terminal-mac.input-lease-flag/1","owner":"","deadline":3000}"#,
            #"{"schema":"terminal-mac.input-lease-flag/1","owner":"bad owner","deadline":3000}"#,
            #"{"schema":"terminal-mac.input-lease-flag/1","owner":"mcp","deadline":"future"}"#,
            String(repeating: "x", count: 5000)
        ]
        for payload in scenarios {
            try mailbox.write(Data(payload.utf8), named: name)
            XCTAssertEqual(mailbox.helperUpdateDisposition(now: start), .unconfirmed, payload.prefix(40).description)
            XCTAssertThrowsError(try mailbox.requireNoOutstandingUpdateMarker(now: start))
            XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(name)), Data(payload.utf8))
        }
    }

    func testSymlinkHardlinkFIFOAndDirectoryCannotBeMistakenForNoMarker() throws {
        let (mailbox, directory) = try box()
        let marker = directory.appendingPathComponent(Mailbox.leaseFlagName)
        let target = directory.appendingPathComponent("other")
        try Data("owned synthetic state".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: marker, withDestinationURL: target)
        XCTAssertEqual(mailbox.helperUpdateDisposition(now: start), .unconfirmed)
        try FileManager.default.removeItem(at: marker)
        try FileManager.default.linkItem(at: target, to: marker)
        XCTAssertEqual(mailbox.helperUpdateDisposition(now: start), .unconfirmed)
        try FileManager.default.removeItem(at: marker)
        XCTAssertEqual(mkfifo(marker.path, 0o600), 0)
        XCTAssertEqual(mailbox.helperUpdateDisposition(now: start), .unconfirmed)
        try FileManager.default.removeItem(at: marker)
        try FileManager.default.createDirectory(at: marker, withIntermediateDirectories: false)
        XCTAssertEqual(mailbox.helperUpdateDisposition(now: start), .unconfirmed)
    }

    func testCleanOwnerReleaseButNotForeignOrUnclassifiedRelease() throws {
        let (mailbox, directory) = try box()
        try mailbox.publishLeaseFlag(owner: "viewer", ttl: 120, now: start)
        XCTAssertThrowsError(try mailbox.releaseLeaseFlag(ownedBy: "mcp", now: start))
        XCTAssertNotNil(try mailbox.read(Mailbox.leaseFlagName))
        XCTAssertNoThrow(try mailbox.releaseLeaseFlag(ownedBy: "viewer", now: start.addingTimeInterval(121)))
        XCTAssertEqual(mailbox.helperUpdateDisposition(now: start), .unmarked)
        try mailbox.write(Data("corrupt".utf8), named: Mailbox.leaseFlagName)
        XCTAssertThrowsError(try mailbox.releaseLeaseFlag(ownedBy: "viewer", now: start))
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(Mailbox.leaseFlagName)), Data("corrupt".utf8))
    }

    func testExpiredOrCorruptMarkerCannotBeSilentlyClaimedByNewOwner() throws {
        let (mailbox, _) = try box()
        try mailbox.publishLeaseFlag(owner: "farol-smoke:run-1", ttl: 120, now: start)
        XCTAssertThrowsError(try mailbox.requireNoOutstandingUpdateMarker(now: start.addingTimeInterval(10_000)))
        try mailbox.write(Data("garbled".utf8), named: Mailbox.leaseFlagName)
        XCTAssertThrowsError(try mailbox.requireNoOutstandingUpdateMarker(now: start.addingTimeInterval(10_000)))
    }
}
