import Foundation
import XCTest
@testable import TerminalMacCore

final class TerminalInputContractTests: XCTestCase {
    func testGuardedRequestsUseNewWireVerbs() throws {
        let window = "00000000-0000-4000-8000-000000000001"
        XCTAssertEqual(try TerminalInputContract.wireAction("type", proof: TerminalInputContract.input, pid: "42", window: window), "terminal-type")
        XCTAssertEqual(try TerminalInputContract.wireAction("key", proof: TerminalInputContract.foreground, pid: "42", key: "cmd+n"), "terminal-key")
        XCTAssertEqual(try TerminalInputContract.wireAction("key", proof: nil, pid: nil), "key")
        XCTAssertEqual(try TerminalInputContract.wireAction("terminal-open", proof: nil, pid: nil), "terminal-open")
        // An old helper has no terminal-* branches; it cannot silently type.
        for verb in ["terminal-type", "terminal-key"] {
            XCTAssertThrowsError(try TerminalInputContract.wireAction(verb, proof: nil, pid: nil))
        }
    }

    func testInvalidGuardCannotFallBackToLegacyInput() {
        let window = "00000000-0000-4000-8000-000000000001"
        for pid in ["", "0", "-1", "0042", "42x", "2147483648"] {
            XCTAssertThrowsError(try TerminalInputContract.wireAction("type", proof: TerminalInputContract.input, pid: pid, window: window))
        }
        XCTAssertThrowsError(try TerminalInputContract.wireAction("type", proof: "terminal-input/1", pid: "42"))
        XCTAssertThrowsError(try TerminalInputContract.wireAction("type", proof: TerminalInputContract.foreground, pid: "42"))
        XCTAssertThrowsError(try TerminalInputContract.wireAction("click", proof: TerminalInputContract.input, pid: "42"))
    }

    func testFocusRequiresTheBoundProcessAndInputRole() throws {
        let window = "00000000-0000-4000-8000-000000000001"
        try TerminalInputContract.requireFocus(proof: TerminalInputContract.input, expectedPID: "42", actualPID: 42,
            foreground: true, input: true, expectedWindow: window, actualWindow: window)
        for sample in [(Int32(43), true, true), (Int32(42), false, true), (Int32(42), true, false)] {
            XCTAssertThrowsError(try TerminalInputContract.requireFocus(proof: TerminalInputContract.input, expectedPID: "42",
                actualPID: sample.0, foreground: sample.1, input: sample.2,
                expectedWindow: window, actualWindow: window))
        }
        XCTAssertThrowsError(try TerminalInputContract.requireFocus(proof: TerminalInputContract.input, expectedPID: "42",
            actualPID: 42, foreground: true, input: true, expectedWindow: window,
            actualWindow: "00000000-0000-4000-8000-000000000002"))
        XCTAssertThrowsError(try TerminalInputContract.requireFocus(proof: TerminalInputContract.input, expectedPID: "42",
            actualPID: nil, foreground: false, input: false, expectedWindow: window, actualWindow: window))
    }

    func testForegroundProofCannotSubmitReturnTextOrOtherShortcuts() throws {
        let window = "00000000-0000-4000-8000-000000000001"
        XCTAssertEqual(try TerminalInputContract.wireAction("key", proof: TerminalInputContract.foreground,
            pid: "42", key: "cmd+n"), "terminal-key")
        try TerminalInputContract.requireFocus(proof: TerminalInputContract.foreground, expectedPID: "42",
            actualPID: 42, foreground: true, input: false, key: "cmd+n")
        for unsafe in ["return", "cmd+o", "cmd+v", "cmd+q"] {
            XCTAssertThrowsError(try TerminalInputContract.wireAction("key", proof: TerminalInputContract.foreground,
                pid: "42", key: unsafe))
            XCTAssertThrowsError(try TerminalInputContract.requireFocus(proof: TerminalInputContract.foreground,
                expectedPID: "42", actualPID: 42, foreground: true, input: true, key: unsafe))
        }
        XCTAssertThrowsError(try TerminalInputContract.wireAction("type", proof: TerminalInputContract.foreground,
            pid: "42", window: window))
        XCTAssertThrowsError(try TerminalInputContract.wireAction("key", proof: TerminalInputContract.input,
            pid: "42", key: "return"))
        XCTAssertEqual(try TerminalInputContract.wireAction("key", proof: TerminalInputContract.input,
            pid: "42", window: window, key: "return"), "terminal-key")
    }

    func testFailureBeforeFirstEventIsNoEffect() {
        var progress = InputEffectProgress()
        var posted = 0
        do {
            try progress.perform(check: { throw OutcomeFailure("TERMINAL_FOCUS_UNVERIFIED", outcome: .noEffect) }, effect: { posted += 1 })
            XCTFail("Expected guard refusal")
        } catch {
            XCTAssertEqual(progress.outcome(for: error), .noEffect)
        }
        XCTAssertEqual(posted, 0)
    }

    func testLateFocusLossAfterFirstOrSeveralChunksIsUnknown() throws {
        for successfulChunks in [1, 3] {
            var progress = InputEffectProgress()
            var posted = 0
            for _ in 0..<successfulChunks {
                try progress.perform(check: {}, effect: { posted += 1 })
            }
            do {
                try progress.perform(check: { throw OutcomeFailure("TERMINAL_FOCUS_UNVERIFIED", outcome: .noEffect) }, effect: { posted += 1 })
                XCTFail("Expected late guard refusal")
            } catch {
                XCTAssertEqual(progress.outcome(for: error), .mutationUnknown)
            }
            XCTAssertEqual(posted, successfulChunks)
        }
    }

    func testErrorInsideFirstPostIsConservativelyUnknown() {
        var progress = InputEffectProgress()
        do {
            try progress.perform(check: {}, effect: { throw Failure("synthetic event submission error") })
            XCTFail("Expected submission failure")
        } catch {
            XCTAssertEqual(progress.outcome(for: error), .mutationUnknown)
        }
    }

    func testKeyDownThenKeyUpFailureCannotBeNoEffect() throws {
        var progress = InputEffectProgress()
        try progress.perform(check: {}, effect: {})
        let failure = OutcomeFailure("TERMINAL_FOCUS_UNVERIFIED", outcome: .noEffect)
        XCTAssertEqual(progress.outcome(for: failure), .mutationUnknown)
    }

    func testFinalReturnRefusalDoesNotRewriteEarlierTextOutcome() throws {
        var text = InputEffectProgress()
        try text.perform(check: {}, effect: {})
        let finalReturn = InputEffectProgress()
        let refused = OutcomeFailure("TERMINAL_FOCUS_UNVERIFIED", outcome: .noEffect)
        XCTAssertEqual(finalReturn.outcome(for: refused), .noEffect)
        XCTAssertTrue(text.started, "a separate refused Return cannot erase earlier command text")
    }

    func testConfirmedNoCopyRemainsAnExplicitDistinctOutcome() throws {
        var progress = InputEffectProgress()
        try progress.perform(check: {}, effect: {})
        XCTAssertEqual(progress.outcome(for: OutcomeFailure("nothing copied", outcome: .confirmedNoCopy)), .confirmedNoCopy)
    }

    func testDiagnosticNeverCopiesArbitraryErrorText() throws {
        let secret = "SYNTHETIC-PRIVATE-TEXT /private/path --text payload"
        for error: Error in [Failure(secret), OutcomeFailure(secret, outcome: .mutationUnknown)] {
            let value = ActionFailureDiagnostic(error: error, dispatched: true, phase: secret)
            let data = try JSONEncoder().encode(value)
            let text = String(decoding: data, as: UTF8.self)
            XCTAssertFalse(text.contains(secret))
            XCTAssertEqual(value.reason, "UNCLASSIFIED")
            XCTAssertEqual(value.outcome, "mutationUnknown")
            XCTAssertEqual(value.phase, "unknown")
        }
    }

    func testStructuredFailureKeepsKnownReasonAndDispatchBoundary() {
        let before = ActionFailureDiagnostic(error: Failure("private detail"), dispatched: false, phase: "admission")
        XCTAssertEqual(before.outcome, "noEffect")
        let timeout = ActionFailureDiagnostic(error: MailboxTimeout(action: "type", pickedUp: false), dispatched: true, phase: "dispatch")
        XCTAssertEqual(timeout.reason, "MAILBOX_TIMEOUT")
        XCTAssertEqual(timeout.outcome, "mutationUnknown")
        let focused = ActionFailureDiagnostic(error: OutcomeFailure("TERMINAL_FOCUS_UNVERIFIED", outcome: .noEffect), dispatched: true, phase: "dispatch")
        XCTAssertEqual(focused.reason, "TERMINAL_FOCUS_UNVERIFIED")
        XCTAssertEqual(focused.outcome, "noEffect")
    }
}
