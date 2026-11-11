import Foundation

/// Resolve a guest action without filesystem probes or default-target guessing.
/// `--vm NAME` is canonical. Unambiguous legacy forms remain supported.
public struct GuestActionTarget {
    public static let actions: Set<String> = [
        "status", "screenshot", "snapshot", "click", "move", "drag", "scroll",
        "type", "key", "clipboard-paste", "clipboard-copy",
        "terminal-open", "terminal-type", "terminal-key"
    ]

    public let name: String
    public let verb: String
    public let operands: [String]

    public init(positionals: [String], explicitName: String? = nil) throws {
        var remaining = positionals
        let name: String
        if let explicitName {
            name = explicitName
        } else if let first = remaining.first, Self.actions.contains(first) {
            // Both `action VM VERB` and `action VERB TEXT` may parse here.
            // Never resolve this by VM existence: that would change the target
            // of an existing command merely because another VM was created.
            if remaining.count >= 2, Self.actions.contains(remaining[1]) {
                throw Failure("Ambiguous VM/action; use action --vm NAME ACTION, or --text for a default-target text payload")
            }
            name = "default"
        } else {
            guard !remaining.isEmpty else {
                throw Failure("Usage: terminal-mac action --vm NAME ACTION [arguments]")
            }
            name = remaining.removeFirst()
        }
        try validateName(name)
        guard let verb = remaining.first, Self.actions.contains(verb) else {
            throw Failure("Unknown or missing guest action")
        }
        self.name = name
        self.verb = verb
        self.operands = Array(remaining.dropFirst())
    }
}
