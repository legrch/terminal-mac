import XCTest
@testable import TerminalMacCore

final class GuestStopConfirmationTests: XCTestCase {
    func testPressIsAdmissibleOnlyWhileStoppingWithFreeLeaseAndAccessibleHelper() {
        for state in ["stopping", GuestStopConfirmation.awaitingState] {
            XCTAssertTrue(GuestStopConfirmation.admissible(runtimeState: state, lease: .allowed, helperAccessibility: "true"))
        }
        for state in ["running", "stopped", "paused", "starting", "error", ""] {
            XCTAssertFalse(GuestStopConfirmation.admissible(runtimeState: state, lease: .allowed, helperAccessibility: "true"), state)
        }
        for lease: InputLease.Admission in [.locked(owner: "other"), .lockedUnknown, .lockedUnresolved] {
            XCTAssertFalse(GuestStopConfirmation.admissible(runtimeState: "stopping", lease: lease, helperAccessibility: "true"))
        }
        for accessibility in ["false", "", nil] as [String?] {
            XCTAssertFalse(GuestStopConfirmation.admissible(runtimeState: "stopping", lease: .allowed, helperAccessibility: accessibility))
        }
    }

    func testOnlyTheLoginWindowShutDownButtonMatches() {
        XCTAssertTrue(GuestStopConfirmation.isSystemShutdownButton(ownerBundle: "com.apple.loginwindow", role: "AXButton", title: "Shut Down"))
        XCTAssertFalse(GuestStopConfirmation.isSystemShutdownButton(ownerBundle: "com.apple.loginwindow", role: "AXButton", title: "Restart"))
        XCTAssertFalse(GuestStopConfirmation.isSystemShutdownButton(ownerBundle: "com.apple.loginwindow", role: "AXButton", title: "Cancel"))
        XCTAssertFalse(GuestStopConfirmation.isSystemShutdownButton(ownerBundle: "com.apple.loginwindow", role: "AXStaticText", title: "Shut Down"))
        XCTAssertFalse(GuestStopConfirmation.isSystemShutdownButton(ownerBundle: "com.example.app", role: "AXButton", title: "Shut Down"))
        XCTAssertFalse(GuestStopConfirmation.isSystemShutdownButton(ownerBundle: nil, role: "AXButton", title: "Shut Down"))
        XCTAssertFalse(GuestStopConfirmation.isSystemShutdownButton(ownerBundle: "com.apple.loginwindow", role: "AXButton", title: "shut down"))
    }
    func testLostPressReplyRetainsGenerationAttemptAndRefusesSecondCaller() async throws {
        let directory = testTemporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let mailbox = try Mailbox(directory.appendingPathComponent("exchange"), create: true)
        let generation = UUID().uuidString.lowercased()
        var presses = 0
        func press() async throws -> Reply {
            try await GuestStopConfirmation.attempt(directory: directory, mailbox: mailbox,
                runtimeStatus: { ["state": "stopping", "generation": generation] }, guest: { request in
                    if request.action == "status" { return Reply(id: request.id, values: ["accessibility": "true"]) }
                    presses += 1
                    XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("shutdown-confirmation-" + generation + ".json").path))
                    throw MailboxTimeout(action: request.action, pickedUp: true)
                })
        }
        do { _ = try await press(); XCTFail("Reply lost") } catch {}
        do { _ = try await press(); XCTFail("Never repeat the press") } catch {}
        XCTAssertEqual(presses, 1)
        XCTAssertEqual(try InputLease.probe(directory: directory), .unresolved)
        XCTAssertFalse(mailbox.helperUpdateDisposition().mayUpdate)
    }

    @MainActor
    func testConcurrentConfirmationCallersPressOnlyOnce() async throws {
        let directory = testTemporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let mailbox = try Mailbox(directory.appendingPathComponent("exchange"), create: true)
        let generation = UUID().uuidString.lowercased()
        var presses = 0
        func press() async throws -> Reply {
            try await GuestStopConfirmation.attempt(directory: directory, mailbox: mailbox,
                runtimeStatus: { ["state": "stopping", "generation": generation] }, guest: { request in
                    if request.action == "status" {
                        try await Task.sleep(nanoseconds: 20_000_000)
                        return Reply(id: request.id, values: ["accessibility": "true"])
                    }
                    presses += 1
                    return Reply(id: request.id, values: ["pressed": "true"])
                })
        }
        let first = Task { try await press() }
        let second = Task { try await press() }
        var successes = 0
        for caller in [first, second] {
            do { _ = try await caller.value; successes += 1 } catch {}
        }
        XCTAssertEqual(successes, 1)
        XCTAssertEqual(presses, 1)
        do { _ = try await press(); XCTFail("Confirmed press is still single-shot for this generation") } catch {}
        XCTAssertEqual(presses, 1)
    }

}
