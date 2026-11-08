import Foundation
import XCTest
@testable import TerminalMacCore

// Typed outcome provenance across the mailbox boundary, and what each outcome means for input
// queued behind a failed action. Unclassified failures (old helpers, plain errors) must stop the
// queue; only proven no-effect and confirmed-no-copy outcomes may proceed.
final class OutcomeDispositionTests: XCTestCase {
    func testDispositionMapping() {
        XCTAssertEqual(InputQueue.disposition(for: OutcomeFailure("expired", outcome: .noEffect)), .proceed)
        XCTAssertEqual(InputQueue.disposition(for: OutcomeFailure("nothing copied", outcome: .confirmedNoCopy)), .proceed)
        XCTAssertEqual(InputQueue.disposition(for: OutcomeFailure("unknown", outcome: .mutationUnknown)), .stop)
        XCTAssertEqual(InputQueue.disposition(for: MailboxTimeout(action: "key", pickedUp: false)), .proceed)
        XCTAssertEqual(InputQueue.disposition(for: MailboxTimeout(action: "key", pickedUp: true)), .stop)
        XCTAssertEqual(InputQueue.disposition(for: Failure("unclassified remote error")), .stop)
        XCTAssertEqual(InputQueue.disposition(for: CancellationError()), .stop)
    }

    func testTimeoutBeforePickupIsKnownNoEffect() async throws {
        let mailbox = try Mailbox(temporary())
        let request = Request(action: "click", timeout: 0.05)
        do {
            _ = try await mailbox.call(request)
            XCTFail("Expected timeout")
        } catch let timeout as MailboxTimeout {
            // The request was never read, so no guest effect can have started.
            XCTAssertFalse(timeout.pickedUp)
            XCTAssertEqual(InputQueue.disposition(for: timeout), .proceed)
        }
        XCTAssertNil(try mailbox.read("request-\(request.id.uuidString).json"))
    }

    func testTimeoutAfterPickupIsUnresolved() async throws {
        let root = try temporary()
        let client = try Mailbox(root)
        let server = try Mailbox(root)
        let request = Request(action: "click", timeout: 0.15)
        let caller = Task { try await client.call(request) }
        for _ in 0..<100 {
            if try server.requests().first != nil { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        do {
            _ = try await caller.value
            XCTFail("Expected timeout")
        } catch let timeout as MailboxTimeout {
            // The helper took the request but never answered: the effect cannot be proven either way.
            XCTAssertTrue(timeout.pickedUp)
            XCTAssertEqual(InputQueue.disposition(for: timeout), .stop)
        }
    }

    func testClassifiedErrorCarriesItsOutcomeToTheCaller() async throws {
        let root = try temporary()
        let client = try Mailbox(root)
        let server = try Mailbox(root)
        let request = Request(action: "clipboard-copy", timeout: 2)
        let caller = Task { try await client.call(request) }
        var received: Request?
        for _ in 0..<100 {
            received = try server.requests().first
            if received != nil { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        try server.respond(Reply(id: request.id, error: "Nothing copied in guest; host clipboard unchanged", outcome: .confirmedNoCopy))
        do {
            _ = try await caller.value
            XCTFail("Expected the classified failure")
        } catch let failure as OutcomeFailure {
            XCTAssertEqual(failure.outcome, .confirmedNoCopy)
            XCTAssertEqual(failure.localizedDescription, "Nothing copied in guest; host clipboard unchanged")
            XCTAssertEqual(InputQueue.disposition(for: failure), .proceed)
        }
    }

    func testUnclassifiedErrorReplyIsTreatedAsMutationUnknown() async throws {
        let root = try temporary()
        let client = try Mailbox(root)
        let server = try Mailbox(root)
        let request = Request(action: "clipboard-paste", timeout: 2)
        let caller = Task { try await client.call(request) }
        var received: Request?
        for _ in 0..<100 {
            received = try server.requests().first
            if received != nil { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        // An old helper reports only an error string: nobody proved what happened.
        try server.respond(Reply(id: request.id, error: "Something failed"))
        do {
            _ = try await caller.value
            XCTFail("Expected the unclassified failure")
        } catch let failure as OutcomeFailure {
            XCTAssertEqual(failure.outcome, .mutationUnknown)
            XCTAssertEqual(InputQueue.disposition(for: failure), .stop)
        }
    }

    func testReplyOutcomeEncodingDecodesOldRepliesAndOmitsAbsentClassification() throws {
        let classified = try JSONEncoder().encode(Reply(id: UUID(), error: "boom", outcome: .confirmedNoCopy))
        let json = try JSONSerialization.jsonObject(with: classified) as! [String: Any]
        XCTAssertEqual(json["outcome"] as? String, "confirmedNoCopy")
        let legacy = try JSONDecoder().decode(Reply.self, from: Data(#"{"id":"00000000-0000-4000-8000-000000000003","ok":false,"values":{},"error":"old helper"}"#.utf8))
        XCTAssertNil(legacy.outcome)
        let success = String(decoding: try JSONEncoder().encode(Reply(id: UUID(), values: ["done": "true"])), as: UTF8.self)
        XCTAssertFalse(success.contains(#""outcome""#))
    }

    func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("terminal-mac-outcome-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
