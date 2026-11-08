import Foundation
import XCTest
@testable import TerminalMacCore

// Regression tests for caller-owned reply publication. No real clipboard: only synthetic text
// crosses a temporary mailbox. A reply that arrives after the caller stopped waiting must never
// recreate a named file, and a late helper must be refused instead of silently dropped.
final class MailboxRetentionRegressionTests: XCTestCase {
    private func mailboxPair() throws -> (Mailbox, Mailbox, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mailbox-retention-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (try Mailbox(root), try Mailbox(root), root)
    }

    private func collect(_ server: Mailbox) async throws -> Request {
        for _ in 0..<100 {
            if let request = try server.requests().first { return request }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        throw Failure("Synthetic caller did not publish a request")
    }

    func testLateCopyReplyCannotReappearAfterCallerTimeout() async throws {
        let (client, server, _) = try mailboxPair()
        let request = Request(action: "clipboard-copy", timeout: 0.15)
        let caller = Task { try await client.call(request) }
        let received = try await collect(server)
        XCTAssertEqual(received.id, request.id)
        do {
            _ = try await caller.value
            XCTFail("Expected caller timeout")
        } catch {
            XCTAssertTrue(error is MailboxTimeout)
        }
        // Deterministic order: caller's defer has completed before late publication.
        do { try server.respond(Reply(id: received.id, values: ["text": "synthetic-late-copy"])) }
        catch { /* A corrected responder may explicitly refuse cancelled ownership. */ }
        XCTAssertNil(try client.read("reply-\(request.id.uuidString).json"),
                     "late reply recreated a named sensitive-text file after timeout cleanup")
    }

    func testLateCopyReplyCannotReappearAfterCallerCancellation() async throws {
        let (client, server, _) = try mailboxPair()
        let request = Request(action: "clipboard-copy", timeout: 2)
        let caller = Task { try await client.call(request) }
        let received = try await collect(server)
        caller.cancel()
        do {
            _ = try await caller.value
            XCTFail("Expected caller cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        do { try server.respond(Reply(id: received.id, values: ["text": "synthetic-cancelled-copy"])) }
        catch { /* Refusal is safe only if no named sensitive reply survives. */ }
        XCTAssertNil(try client.read("reply-\(request.id.uuidString).json"))
    }

    func testOrdinaryCopyReplyIsDeliveredAndCleaned() async throws {
        let (client, server, _) = try mailboxPair()
        let request = Request(action: "clipboard-copy", timeout: 2)
        let caller = Task { try await client.call(request) }
        let received = try await collect(server)
        try server.respond(Reply(id: received.id, values: ["text": "synthetic-success"]))
        let reply = try await caller.value
        XCTAssertEqual(reply.values["text"], "synthetic-success")
        XCTAssertNil(try client.read("reply-\(request.id.uuidString).json"))
    }

    func testRespondRefusesWhenNoCallerOwnsTheSlot() throws {
        let (server, _, _) = try mailboxPair()
        // Without a caller-created slot there is no owner: publication must fail closed instead
        // of leaving an ownerless named file behind.
        XCTAssertThrowsError(try server.respond(Reply(id: UUID(), values: ["text": "synthetic-unowned"])))
    }

    func testReplySlotIsRefusedWhenPreparedTwice() throws {
        let (client, _, _) = try mailboxPair()
        let name = "reply-\(UUID().uuidString).json"
        try client.prepareSlot(name)
        XCTAssertThrowsError(try client.prepareSlot(name))
        XCTAssertNotNil(try client.read(name))
    }

    func testPartialPublicationIsPolledUntilComplete() async throws {
        // A responder writes the slot in place, so intermediate bytes can be observed; the caller
        // waits for the complete reply instead of failing on a partial payload.
        let (client, server, _) = try mailboxPair()
        let request = Request(action: "status", timeout: 2)
        let caller = Task { try await client.call(request) }
        let received = try await collect(server)
        try server.write(Data("not-a-complete-reply".utf8), named: "reply-\(request.id.uuidString).json")
        try server.respond(Reply(id: received.id, values: ["done": "true"]))
        let reply = try await caller.value
        XCTAssertEqual(reply.values["done"], "true")
    }

    func testStaleResidueIsSweptWhileLiveSlotsSurvive() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mailbox-sweep-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let server = try Mailbox(root)
        let staleReply = "reply-00000000-0000-4000-8000-000000000001.json"
        let staleImage = "image-00000000-0000-4000-8000-000000000002.bin"
        for name in [staleReply, staleImage] { try Data("orphaned residue".utf8).write(to: root.appendingPathComponent(name)) }
        let backdated = Date().addingTimeInterval(-(Mailbox.residueAge + 60))
        for name in [staleReply, staleImage] {
            try FileManager.default.setAttributes([.modificationDate: backdated], ofItemAtPath: root.appendingPathComponent(name).path)
        }
        // A slot owned by a call that is still waiting must never be swept.
        let live = "reply-\(UUID().uuidString).json"
        try server.prepareSlot(live)
        _ = try server.requests()
        XCTAssertNil(try server.read(staleReply))
        XCTAssertNil(try server.read(staleImage))
        XCTAssertNotNil(try server.read(live))
    }
}
