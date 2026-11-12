import Foundation

/// An unconfirmed guest effect freezes mutation for this live MCP session.
/// Read-only observations can reconcile evidence but never reset this gate.
public struct GuestSessionOutcomeGuard {
    public private(set) var isUnconfirmed = false
    public init() {}
    public mutating func markUnconfirmed() { isUnconfirmed = true }
    public func requireAllowed(action: String) throws {
        guard !isUnconfirmed || action == "status" || action == "screenshot" else {
            throw Failure("Guest action outcome is unconfirmed; only status and screenshot are allowed. Reconcile the original operation before starting another session.")
        }
    }
}
