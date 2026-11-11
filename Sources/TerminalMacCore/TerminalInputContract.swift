import Foundation

/// Wire verbs are deliberately distinct from legacy key/type. An older helper
/// must reject a guarded request, not ignore an unfamiliar argument and type.
public enum TerminalInputContract {
    public static let version = "terminal-input/2"
    public static let launchVersion = "terminal-launch/1"
    public static let foreground = "terminal-foreground/2"
    public static let input = "terminal-input/2"

    public static func wireAction(_ verb: String, proof: String?, pid: String?, window: String? = nil, key: String? = nil) throws -> String {
        let guardedVerb = verb == "terminal-type" || verb == "terminal-key"
        guard proof != nil || pid != nil || window != nil || guardedVerb else { return verb }
        guard ["key", "type", "terminal-key", "terminal-type"].contains(verb),
              let proof, [foreground, input].contains(proof),
              let pid, let number = Int32(pid), number > 0,
              pid == String(number) else {
            throw OutcomeFailure("TERMINAL_GUARD_INVALID", outcome: .noEffect)
        }
        // Foreground-only proof is deliberately limited to the bootstrap window
        // creation shortcut. Return, text and all other shortcuts need a bound
        // focused input element, not just the foreground Terminal application.
        if proof == foreground {
            guard (verb == "key" || verb == "terminal-key") && key == "cmd+n" else {
                throw OutcomeFailure("TERMINAL_GUARD_INVALID", outcome: .noEffect)
            }
        }
        if proof == input || window != nil {
            guard let window, UUID(uuidString: window)?.uuidString == window else {
                throw OutcomeFailure("TERMINAL_GUARD_INVALID", outcome: .noEffect)
            }
        }
        // Text always requires a focused Terminal text area, never just its app.
        if verb == "type" || verb == "terminal-type" {
            guard proof == input else { throw OutcomeFailure("TERMINAL_GUARD_INVALID", outcome: .noEffect) }
            return "terminal-type"
        }
        return "terminal-key"
    }

    public static func requireFocus(proof: String?, expectedPID: String?,
                                    actualPID: Int32?, foreground: Bool, input: Bool,
                                    expectedWindow: String? = nil, actualWindow: String? = nil,
                                    key: String? = nil) throws {
        guard let proof, [self.foreground, self.input].contains(proof),
              let expectedPID, let expected = Int32(expectedPID), expected > 0,
              expectedPID == String(expected) else {
            throw OutcomeFailure("TERMINAL_GUARD_INVALID", outcome: .noEffect)
        }
        if proof == self.foreground && key != "cmd+n" {
            throw OutcomeFailure("TERMINAL_GUARD_INVALID", outcome: .noEffect)
        }
        if proof == self.input || expectedWindow != nil {
            guard let expectedWindow, UUID(uuidString: expectedWindow)?.uuidString == expectedWindow else {
                throw OutcomeFailure("TERMINAL_GUARD_INVALID", outcome: .noEffect)
            }
            guard actualWindow == expectedWindow else {
                throw OutcomeFailure("TERMINAL_FOCUS_UNVERIFIED", outcome: .noEffect)
            }
        }
        guard foreground, actualPID == expected, proof != self.input || input else {
            throw OutcomeFailure("TERMINAL_FOCUS_UNVERIFIED", outcome: .noEffect)
        }
    }
}

/// Tracks effects of ONE request. A late precondition failure cannot undo an
/// already posted chunk/key. A confirmed no-copy is a separate, explicit result.
public struct InputEffectProgress {
    public private(set) var started = false
    public init() {}
    public mutating func begin() { started = true }
    public mutating func perform(check: () throws -> Void, effect: () throws -> Void) throws {
        try check()
        started = true
        try effect()
    }
    public func outcome(for error: Error) -> GuestOutcome {
        let reported = (error as? OutcomeFailure)?.outcome
        if reported == .confirmedNoCopy { return .confirmedNoCopy }
        if started { return .mutationUnknown }
        return reported ?? .noEffect
    }
}

/// This envelope contains only allowlisted codes, never localized error text,
/// argv operands, filenames, window contents, stdout/stderr or lease-owner IDs.
public struct ActionFailureDiagnostic: Encodable {
    public let schema = "terminal-mac.action-error/1"
    public let reason: String
    public let outcome: String
    public let phase: String

    public init(error: Error, dispatched: Bool, phase: String) {
        let allowed = ["TERMINAL_GUARD_INVALID", "TERMINAL_FOCUS_UNVERIFIED",
                       "TERMINAL_LAUNCH_UNAVAILABLE", "TERMINAL_LAUNCH_UNCONFIRMED",
                       "TERMINAL_CAPABILITY_UNSUPPORTED"]
        if let failure = error as? OutcomeFailure {
            reason = allowed.contains(failure.message) ? failure.message : "UNCLASSIFIED"
            outcome = failure.outcome.rawValue
        } else if error is MailboxTimeout {
            reason = "MAILBOX_TIMEOUT"
            outcome = "mutationUnknown"
        } else if error is CancellationError {
            reason = "CANCELLED"
            outcome = dispatched ? "mutationUnknown" : "noEffect"
        } else {
            reason = "UNCLASSIFIED"
            outcome = dispatched ? "mutationUnknown" : "noEffect"
        }
        self.phase = ["validation", "admission", "dispatch", "output"].contains(phase) ? phase : "unknown"
    }
}
