import Foundation
import XCTest
@testable import TerminalMacCore
@testable import TerminalMac

@MainActor
final class NativeClipboardCustodyTests: XCTestCase {
    private func fixture() throws -> (URL, Mailbox) {
        let root = testTemporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (root, try Mailbox(root.appendingPathComponent("exchange"), create: true))
    }
    func testLostNativePasteReplyFencesFurtherTransfersAndOtherClients() async throws {
        let (directory, mailbox) = try fixture()
        let session = NativeClipboardCustody(directory: directory, windowOwner: { nil })
        let request = Request(action: "clipboard-paste", timeout: 0.01)
        do {
            try await session.perform(request: request, mailbox: mailbox) {
                XCTAssertFalse(mailbox.helperUpdateDisposition().mayUpdate)
                XCTAssertThrowsError(try InputLease.acquire(directory: directory, owner: "racer", generation: 2))
                _ = try await mailbox.call(request)
            }
            XCTFail("No reply")
        } catch { XCTAssertTrue(error is MailboxTimeout) }
        XCTAssertTrue(session.isUnconfirmed)
        XCTAssertEqual(try InputLease.probe(directory: directory), .unresolved)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(InputLease.metadataName).path))
        XCTAssertFalse(mailbox.helperUpdateDisposition().mayUpdate)
        var replayed = false
        do {
            try await session.perform(request: Request(action: "clipboard-paste"), mailbox: mailbox) { replayed = true }
            XCTFail("Unknown native transfer must freeze input")
        } catch {}
        XCTAssertFalse(replayed)
        XCTAssertThrowsError(try InputLease.acquire(directory: directory, owner: "next-client", generation: 3))
    }
    func testCancellationAndMutationUnknownRetainNativeCustody() async throws {
        for failure: Error in [CancellationError(), OutcomeFailure("unconfirmed", outcome: .mutationUnknown)] {
            let (directory, mailbox) = try fixture()
            let session = NativeClipboardCustody(directory: directory, windowOwner: { nil })
            do {
                try await session.perform(request: Request(action: "clipboard-copy"), mailbox: mailbox) { throw failure }
                XCTFail("Unknown effect")
            } catch {}
            XCTAssertTrue(session.isUnconfirmed)
            XCTAssertEqual(try InputLease.probe(directory: directory), .unresolved)
            XCTAssertFalse(mailbox.helperUpdateDisposition().mayUpdate)
        }
    }
    func testNativeTransferBorrowsWindowOwnerAndReleasesOnlyItsOperation() async throws {
        let (directory, mailbox) = try fixture()
        let holder = try InputLease.acquire(directory: directory, owner: "viewer", generation: 1)
        defer { holder.release() }
        try mailbox.publishLeaseFlag(owner: holder.owner, ttl: 120)
        let session = NativeClipboardCustody(directory: directory, windowOwner: { holder.owner })
        var dispatched = 0
        try await session.perform(request: Request(action: "clipboard-copy"), mailbox: mailbox) { dispatched += 1 }
        XCTAssertEqual(dispatched, 1)
        XCTAssertEqual(try InputLease.probe(directory: directory), .held(owner: holder.owner, generation: 1))
        XCTAssertFalse(mailbox.helperUpdateDisposition().mayUpdate)
        let foreign = NativeClipboardCustody(directory: directory, windowOwner: { "foreign" })
        do {
            try await foreign.perform(request: Request(action: "clipboard-paste"), mailbox: mailbox) { dispatched += 1 }
            XCTFail("Foreign custody must be refused")
        } catch {}
        XCTAssertEqual(dispatched, 1)
        try mailbox.releaseLeaseFlag(ownedBy: holder.owner)
    }
}
