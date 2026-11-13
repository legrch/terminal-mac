import Foundation

/// A virtual power-button press makes macOS show its own "shut down now?"
/// confirmation. The host never confirms it by default. The explicit
/// `stop --confirm-guest-dialog` may press exactly that system button once.
public enum GuestStopConfirmation {
    /// Host runtime state after the guest has not powered off within the window.
    public static let awaitingState = "stopping-awaiting-guest-confirmation"
    public static let guestAction = "confirm-shutdown-dialog"
    public static let ownerBundle = "com.apple.loginwindow"
    public static let buttonTitle = "Shut Down"
    public static let maximumDepth = 8

    /// A press is admissible only while a requested stop is in progress, no
    /// client holds or fences guest input, and a live helper has Accessibility.
    public static func admissible(runtimeState: String, lease: InputLease.Admission,
                                  helperAccessibility: String?) -> Bool {
        (runtimeState == "stopping" || runtimeState == awaitingState) &&
            lease == .allowed && helperAccessibility == "true"
    }

    /// Serialize status observation and the single press under durable input custody.
    /// The immutable attempt belongs to the original runtime generation, never
    /// to a CLI invocation. Neither a lost reply nor an unconfirmed AX result
    /// authorizes another press in that generation.
    public static func attempt(directory: URL, mailbox: Mailbox,
                               runtimeStatus: () async throws -> [String: String],
                               guest: (Request) async throws -> Reply) async throws -> Reply {
        let request = Request(action: guestAction, timeout: 15)
        let custody = try GuestInputCustody.begin(directory: directory, mailbox: mailbox, request: request)
        return try await custody.perform {
            let status = try await runtimeStatus()
            guard let generation = status["generation"], UUID(uuidString: generation) != nil else {
                throw OutcomeFailure("Runtime generation is unavailable; refuse confirmation", outcome: .noEffect)
            }
            let helper = try await guest(Request(action: "status", timeout: 10))
            guard admissible(runtimeState: status["state"] ?? "unknown", lease: .allowed,
                             helperAccessibility: helper.values["accessibility"]) else {
                throw OutcomeFailure("Guest shutdown confirmation is not admissible", outcome: .noEffect)
            }
            let evidence = try AppServiceDirectory.open(directory)
            let name = "shutdown-confirmation-" + generation.lowercased() + ".json"
            guard try evidence.read(name, limit: 4096) == nil else {
                throw OutcomeFailure("Shutdown confirmation was already attempted; reconcile the original press", outcome: .noEffect)
            }
            do {
                try evidence.write(JSONSerialization.data(withJSONObject: [
                    "schema": "terminal-mac.shutdown-confirmation/1", "generation": generation,
                    "operationID": request.id.uuidString]), named: name, createOnly: true)
            } catch {
                throw OutcomeFailure("Shutdown confirmation fence publication is unconfirmed", outcome: .mutationUnknown)
            }
            let reply = try await guest(request)
            guard reply.values["pressed"] == "true" else {
                throw OutcomeFailure("Shutdown confirmation press is unconfirmed", outcome: .mutationUnknown)
            }
            return reply
        }
    }

    /// Only the system shutdown confirmation's own button: loginwindow, AXButton,
    /// exact title. Any other application, role or title is never pressed.
    public static func isSystemShutdownButton(ownerBundle: String?, role: String?, title: String?) -> Bool {
        ownerBundle == Self.ownerBundle && role == "AXButton" && title == buttonTitle
    }
}
