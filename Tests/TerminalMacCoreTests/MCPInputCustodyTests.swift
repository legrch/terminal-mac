import Darwin
import Foundation
import XCTest
@testable import TerminalMacCore
@testable import TerminalMac

/// The real AgentServer dispatch against disposable files and scripted replies.
/// A held fixture runtime flock replaces a VM; no process or machine is started.
@MainActor
final class MCPInputCustodyTests: XCTestCase {
    private func fixture() throws -> (AgentServer, URL, Mailbox, InputLease) {
        let root = testTemporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = Store(root: root), directory = try store.directory("fixture")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try store.save(Machine(name: "fixture", cpu: 2, memoryGiB: 2, diskGiB: 8))
        let runtime = open(directory.appendingPathComponent("runtime.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard runtime >= 0 else { throw Failure("Cannot create fixture runtime lock") }
        guard flock(runtime, LOCK_EX | LOCK_NB) == 0 else { close(runtime); throw Failure("Cannot lock fixture runtime") }
        addTeardownBlock {
            _ = flock(runtime, LOCK_UN); close(runtime)
            try? FileManager.default.removeItem(at: root)
        }
        let server = AgentServer(store: store, name: "fixture")
        let lease = try InputLease.acquire(directory: directory, owner: server.sessionOwner, generation: 1)
        let box = try Mailbox(directory.appendingPathComponent("exchange"), create: true)
        try box.publishLeaseFlag(owner: lease.owner, ttl: 120)
        return (server, directory, box, lease)
    }
    private func respond(_ box: Mailbox, inspect: @escaping (Request) throws -> Reply) -> Task<Void, Error> {
        Task { @MainActor in
            for _ in 0..<200 {
                if let request = try box.requests().first {
                    try box.respond(inspect(request)); return
                }
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            XCTFail("No fixture request received")
        }
    }
    func testMCPMutationPublishesFenceAndSerializesCooperativeCalls() async throws {
        let (server, directory, box, holder) = try fixture()
        defer { holder.release(preserveMetadata: true) }
        let responder = respond(box) { request in
            XCTAssertTrue(try InputLease.hasOperationFence(directory))
            XCTAssertFalse(box.helperUpdateDisposition().mayUpdate)
            XCTAssertThrowsError(try GuestInputCustody.begin(directory: directory, mailbox: box,
                request: Request(action: "key"), claimedOwner: holder.owner))
            return Reply(id: request.id)
        }
        _ = try await server.guest(Request(action: "type", arguments: ["text": "fixture"]), mailbox: box)
        try await responder.value
        XCTAssertFalse(try InputLease.hasOperationFence(directory))
        XCTAssertEqual(try InputLease.probe(directory: directory), .held(owner: holder.owner, generation: 1))
        try box.releaseLeaseFlag(ownedBy: holder.owner)
        holder.release()
    }
    func testCooperativeUnknownPreventsLiveMCPInputAndQuitCloseDispatch() async throws {
        let (server, directory, box, holder) = try fixture()
        defer { holder.release(preserveMetadata: true) }
        // Native clipboard now refuses this owner entirely. A cooperating CLI
        // can still dispatch, so its lost reply must inhibit this live MCP too.
        let request = Request(action: "clipboard-paste", timeout: 0.01)
        let operation = try GuestInputCustody.begin(directory: directory, mailbox: box,
            request: request, claimedOwner: holder.owner)
        do { _ = try await operation.perform { try await box.call(request) }; XCTFail("No helper reply") }
        catch { XCTAssertTrue(error is MailboxTimeout) }
        let calls: [(String, [String: String])] = [
            ("type", [:]), ("key", [:]), ("click", [:]),
            ("app-service", ["serviceCommand": "quit"]), ("app-service", ["serviceCommand": "close"])
        ]
        for (action, arguments) in calls {
            let request = Request(action: action, arguments: arguments, timeout: 0.01)
            do { _ = try await server.guest(request, mailbox: box); XCTFail("Retained operation must prevent dispatch") }
            catch { XCTAssertFalse(error is MailboxTimeout, "Admission must refuse before mailbox.call") }
        }
        XCTAssertTrue(try box.requests().isEmpty)
        XCTAssertTrue(try InputLease.hasOperationFence(directory))
        XCTAssertFalse(box.helperUpdateDisposition().mayUpdate)
    }
    func testUnknownMCPMutationRetainsFenceAndAllowsReadonlyObservations() async throws {
        let (server, directory, box, holder) = try fixture()
        defer { holder.release(preserveMetadata: true) }
        do { _ = try await server.guest(Request(action: "key", timeout: 0.01), mailbox: box); XCTFail("No helper reply") }
        catch { XCTAssertTrue(error is MailboxTimeout) }
        XCTAssertTrue(try InputLease.hasOperationFence(directory))
        let fence = try Data(contentsOf: directory.appendingPathComponent(InputLease.operationName))
        for request in [Request(action: "status"), Request(action: "screenshot"),
                        Request(action: "app-service", arguments: ["serviceCommand": "observe"])] {
            let responder = respond(box) { Reply(id: $0.id) }
            _ = try await server.guest(request, mailbox: box)
            try await responder.value
        }
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(InputLease.operationName)), fence)
        XCTAssertEqual(try InputLease.probe(directory: directory), .unresolved)
    }
    func testConfirmedNoEffectMCPFailureReleasesOnlyOperationFence() async throws {
        let (server, directory, box, holder) = try fixture()
        defer { holder.release(preserveMetadata: true) }
        let responder = respond(box) { Reply(id: $0.id, error: "Fixture refusal", outcome: .noEffect) }
        do { _ = try await server.guest(Request(action: "key"), mailbox: box); XCTFail("Fixture refusal") }
        catch { XCTAssertEqual((error as? OutcomeFailure)?.outcome, .noEffect) }
        try await responder.value
        XCTAssertFalse(try InputLease.hasOperationFence(directory))
        XCTAssertEqual(try InputLease.probe(directory: directory), .held(owner: holder.owner, generation: 1))
        XCTAssertFalse(box.helperUpdateDisposition().mayUpdate)
        try box.releaseLeaseFlag(ownedBy: holder.owner)
        holder.release()
    }
}
