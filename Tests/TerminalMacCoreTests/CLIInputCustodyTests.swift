import Foundation
import XCTest
@testable import TerminalMacCore
@testable import TerminalMac

@MainActor
final class CLIInputCustodyTests: XCTestCase {
    private func fixture() throws -> (Store, URL, Mailbox) {
        let root = testTemporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = Store(root: root), directory = try store.directory("fixture")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try store.save(Machine(name: "fixture", cpu: 2, memoryGiB: 2, diskGiB: 8))
        let box = try Mailbox(directory.appendingPathComponent("exchange"), create: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (store, directory, box)
    }
    func testLostCLIReplyRetainsCustodyAndRefusesNextMutation() async throws {
        let (store, directory, box) = try fixture()
        let caller = Task { try await CLI(store: store).action(["--vm", "fixture", "key", "return", "--timeout", "1"]) }
        var pickedUp = false
        for _ in 0..<200 {
            if !(try box.requests()).isEmpty { pickedUp = true; break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertTrue(pickedUp)
        XCTAssertThrowsError(try InputLease.acquire(directory: directory, owner: "racer", generation: 2))
        XCTAssertFalse(box.helperUpdateDisposition().mayUpdate)
        do { try await caller.value; XCTFail("Reply was lost") } catch { XCTAssertTrue(error is MailboxTimeout) }
        XCTAssertEqual(try InputLease.probe(directory: directory), .unresolved)
        do {
            try await CLI(store: store).action(["--vm", "fixture", "key", "return", "--timeout", "1"])
            XCTFail("Unknown effect must not be replayed")
        } catch { XCTAssertTrue(error.localizedDescription.contains("unresolved")) }
        XCTAssertTrue(try box.requests().isEmpty)
    }
    func testAcquisitionBetweenProbeAndDispatchRefusesCustody() throws {
        let (_, directory, box) = try fixture()
        var competitor: InputLease?
        defer { competitor?.release() }
        XCTAssertThrowsError(try GuestInputCustody.begin(directory: directory, mailbox: box,
            request: Request(action: "type"), claimedOwner: nil, afterProbe: {
                competitor = try InputLease.acquire(directory: directory, owner: "racer", generation: 2)
            }))
        XCTAssertFalse(try InputLease.hasOperationFence(directory))
        XCTAssertTrue(try box.requests().isEmpty)
    }
    func testCooperativeOwnerRouteCompletesWithoutReleasingHolder() async throws {
        let (store, directory, box) = try fixture()
        let holder = try InputLease.acquire(directory: directory, owner: "scenario", generation: 1)
        defer { holder.release() }
        try box.publishLeaseFlag(owner: holder.owner, ttl: 120)
        let responder = Task {
            for _ in 0..<200 {
                for request in try box.requests() { try box.respond(Reply(id: request.id)); return }
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            XCTFail("No cooperative request")
        }
        try await CLI(store: store).action(["--vm", "fixture", "key", "return", "--owner", holder.owner])
        try await responder.value
        XCTAssertEqual(try InputLease.probe(directory: directory), .held(owner: "scenario", generation: 1))
        XCTAssertFalse(box.helperUpdateDisposition().mayUpdate)
        try box.releaseLeaseFlag(ownedBy: holder.owner)
    }
    func testUnknownBorrowedOwnerCallFencesFurtherOwnerCalls() async throws {
        let (_, directory, box) = try fixture()
        let holder = try InputLease.acquire(directory: directory, owner: "scenario", generation: 1)
        defer { holder.release(preserveMetadata: true) }
        let request = Request(action: "clipboard-paste", timeout: 0.01)
        let custody = try GuestInputCustody.begin(directory: directory, mailbox: box, request: request, claimedOwner: holder.owner)
        do { _ = try await custody.perform { try await box.call(request) }; XCTFail("No helper") } catch {}
        XCTAssertEqual(try InputLease.probe(directory: directory), .unresolved)
        XCTAssertThrowsError(try GuestInputCustody.begin(directory: directory, mailbox: box,
            request: Request(action: "key"), claimedOwner: holder.owner))
    }
    func testBorrowedOwnerReleaseBetweenProbeAndFencePreventsDispatch() throws {
        let (_, directory, box) = try fixture()
        let holder = try InputLease.acquire(directory: directory, owner: "scenario", generation: 1)
        XCTAssertThrowsError(try GuestInputCustody.begin(directory: directory, mailbox: box,
            request: Request(action: "type"), claimedOwner: holder.owner, afterProbe: { holder.release() }))
        XCTAssertTrue(try box.requests().isEmpty)
        XCTAssertTrue(try InputLease.hasOperationFence(directory))
    }

}
