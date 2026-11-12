import CoreFoundation
import CoreGraphics
import Foundation
import ImageIO
import TerminalMacCore
import UniformTypeIdentifiers

/// A Model Context Protocol server over stdio, so agents get computer-use tools for the guest
/// desktop without shelling out: `claude mcp add terminal-mac -- /path/to/terminal-mac mcp`.
/// It only talks to the guest helper's mailbox; it never touches the host desktop.
@MainActor
final class AgentServer {
    let store: Store
    let name: String
    /// Sticky for this session. A crash also leaves the original marker behind.
    private var outcomeGuard = GuestSessionOutcomeGuard()
    let sessionOwner = "mcp:" + UUID().uuidString.lowercased()
    private var guestActionInFlight = false
    private let appSelection: AppMCPSelection?
    private var appSession: AppServiceMCPSession?
    init(store: Store, name: String, appSelection: AppMCPSelection? = nil) {
        self.store = store; self.name = name; self.appSelection = appSelection
    }

    static let instructions = """
    Controls a separate virtual Mac, not the user's own desktop. Call `screenshot` first; every \
    x/y is a pixel in that screenshot (top-left origin), which equals guest screen points. \
    Take another screenshot after actions to check the result. If the guest is at its login \
    screen or a macOS permission prompt appears, ask the user to handle it.
    """

    private static func schema(_ properties: [String: Any], required: [String] = []) -> [String: Any] {
        ["type": "object", "properties": properties, "required": required, "additionalProperties": false]
    }
    private static let point: [String: Any] = ["type": "integer", "minimum": 0]
    private static let after: [String: Any] = ["type": "boolean", "description": "Also return a screenshot taken shortly after the action."]
    static let tools: [[String: Any]] = [
        ["name": "screenshot", "description": "Capture the virtual Mac's screen. Coordinates for other tools are pixels in this image.",
         "inputSchema": schema([:]), "annotations": ["readOnlyHint": true]],
        ["name": "click", "description": "Click at a point. clicks: 2 double-clicks, 3 triple-clicks.",
         "inputSchema": schema(["x": point, "y": point, "button": ["type": "string", "enum": ["left", "right"]],
                                "clicks": ["type": "integer", "minimum": 1, "maximum": 3], "screenshot": after], required: ["x", "y"])],
        ["name": "move", "description": "Move the pointer, for example to reveal a hover menu or tooltip.",
         "inputSchema": schema(["x": point, "y": point, "screenshot": after], required: ["x", "y"])],
        ["name": "drag", "description": "Press the left button at (x, y), drag to (toX, toY) and release. Selects text, moves windows and items.",
         "inputSchema": schema(["x": point, "y": point, "toX": point, "toY": point, "screenshot": after], required: ["x", "y", "toX", "toY"])],
        ["name": "scroll", "description": "Scroll at a point. Negative dy scrolls content down (like swiping up), positive dy scrolls up. Pixels, -1000…1000.",
         "inputSchema": schema(["x": point, "y": point, "dy": ["type": "integer"], "dx": ["type": "integer"], "screenshot": after], required: ["x", "y", "dy"])],
        ["name": "type", "description": "Type literal text into the focused field. Use `key` for return, tab and shortcuts.",
         "inputSchema": schema(["text": ["type": "string"], "screenshot": after], required: ["text"])],
        ["name": "key", "description": "Press a key or chord: return, tab, escape, backspace, up, cmd+space, cmd+tab, cmd+c, cmd+shift+... Modifiers: cmd, ctrl, alt, shift.",
         "inputSchema": schema(["key": ["type": "string"], "screenshot": after], required: ["key"])],
        ["name": "status", "description": "Report whether the VM is running and the guest helper has its privacy permissions.",
         "inputSchema": schema([:]), "annotations": ["readOnlyHint": true]]
    ]

    func run() async throws {
        // InputLease.acquire creates its directories. Validate the selected machine
        // first so an early MCP launch cannot obstruct normal first-use creation.
        _ = try store.load(name)
        // The MCP agent owns guest input while it serves; a competing viewer or scenario is
        // refused at startup instead of interleaving guest actions.
        let lease = try InputLease.acquire(directory: try store.directory(name), owner: sessionOwner,
                                           generation: Int(Date().timeIntervalSince1970))
        // A long-lived MCP server may be idle longer than the 120-second marker TTL.
        // Publish at acquisition, not only on the next tool request. The new helper
        // treats expiry as an inhibitor; no heartbeat/timer is needed for update safety.
        var markerPublished = false
        let updateBox = try? Mailbox(store.directory(name).appendingPathComponent("exchange"), create: true)
        defer {
            var cleanMarkerRelease = false
            if markerPublished && !outcomeGuard.isUnconfirmed && !guestActionInFlight &&
                (appSession?.permitsCleanRelease ?? true), let updateBox {
                do {
                    try updateBox.releaseLeaseFlag(ownedBy: sessionOwner)
                    cleanMarkerRelease = true
                } catch { /* Keep both records for reconciliation. */ }
            }
            // Acquisition already checked predecessor metadata and the marker under flock.
            // A failed initialization, unresolved guest effect or failed marker release must
            // preserve this session's machine metadata too; unlock is NOT effect completion.
            lease.release(preserveMetadata: !cleanMarkerRelease)
        }
        guard let updateBox else { throw Failure("Cannot open guest exchange for helper-update custody") }
        // Defence in depth: refuse a marker newly published after acquisition. Only the
        // pre-publication check inside InputLease.acquire protects predecessor metadata.
        try updateBox.requireNoOutstandingUpdateMarker()
        // Native app-service has a fixed 600s lifetime; publish ONE marker
        // with the SAME immutable owner and no timer-based renewal. Generic MCP
        // retains its original 120s behavior.
        try updateBox.publishLeaseFlag(owner: sessionOwner,
                                       ttl: appSelection == nil ? 120 : AppMCPAdmission.budget)
        markerPublished = true
        if let selection = appSelection {
            let accepted = AppServiceMCPSession(selection: selection, owner: sessionOwner,
                                                machineDirectory: try store.directory(name))
            appSession = accepted
            do {
                try await accepted.bootstrap(
                    host: { request in
                        try await Mailbox(try self.store.directory(self.name)
                            .appendingPathComponent("host-control")).call(request)
                    },
                    guest: { request in try await self.guest(request) })
            } catch {
                if accepted.hasIntent { outcomeGuard.markUnconfirmed() }
                throw error
            }
        }
        for try await line in FileHandle.standardInput.bytes.lines {
            guard let data = line.data(using: .utf8), let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]]); continue
            }
            // Notifications have no id and get no reply.
            guard let id = message["id"] else { continue }
            let params = message["params"] as? [String: Any] ?? [:]
            switch message["method"] as? String {
            case "initialize":
                send(["jsonrpc": "2.0", "id": id, "result": [
                    "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                    "capabilities": ["tools": [:]],
                    "serverInfo": ["name": "terminal-mac", "version": appVersion],
                    "instructions": Self.instructions]])
            case "ping": send(["jsonrpc": "2.0", "id": id, "result": [:]])
            case "tools/list": send(["jsonrpc": "2.0", "id": id, "result": ["tools": Self.tools]])
            case "tools/call":
                let tool = params["name"] as? String ?? ""
                let arguments = params["arguments"] as? [String: Any] ?? [:]
                do { send(["jsonrpc": "2.0", "id": id, "result": ["content": try await call(tool, arguments)]]) }
                catch { send(["jsonrpc": "2.0", "id": id, "result": ["content": [["type": "text", "text": explain(error)]], "isError": true]]) }
            default: send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found"]])
            }
        }
        // Reaching this point is a clean stdio EOF. A crash, thrown stream
        // read or transport interruption does NOT enter native Quit/close.
        if let accepted = appSession {
            // A prior GUI action may have an UNKNOWN outcome independent of
            // the native app-service sequence. Do not even attempt cleanup
            // dispatch in that state; the original marker remains retained.
            guard !outcomeGuard.isUnconfirmed else {
                throw Failure("MCP guest outcome is unconfirmed; no EOF cleanup dispatched")
            }
            do {
                try await accepted.cleanEOF(guest: { request in try await self.guest(request) })
            } catch {
                outcomeGuard.markUnconfirmed()
                throw error
            }
        }
    }

    private func call(_ tool: String, _ a: [String: Any]) async throws -> [[String: Any]] {
        func int(_ key: String) throws -> String {
            guard let number = a[key] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  let value = number as? Int else {
                throw Failure("Expected an integer in range for '\(key)'")
            }
            return String(value)
        }
        func string(_ key: String) throws -> String {
            guard let value = a[key] as? String, !value.isEmpty else { throw Failure("Missing '\(key)'") }
            return value
        }
        var requests: [Request] = []
        if tool != "screenshot" && tool != "status", let accepted = appSession {
            try accepted.requireInteractiveBudget()
        }
        switch tool {
        case "screenshot": return try await screenshot()
        case "status":
            let reply = try await guest(Request(action: "status", timeout: 5))
            let summary = reply.values.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
            let appState = appSession.map { "\n" + $0.summary() } ?? ""
            let custody = outcomeGuard.isUnconfirmed ? "\nGuest input outcome: UNKNOWN; only status/screenshot allowed." : ""
            return [["type": "text", "text": "VM '\(name)' is running.\n" + summary + appState + custody]]
        case "click":
            var base = ["x": try int("x"), "y": try int("y")]
            if a["button"] as? String == "right" { base["button"] = "right" }
            let clicks = max(1, min(3, a["clicks"] as? Int ?? 1))
            // Each extra click continues the sequence, which macOS reads as a double or triple click.
            for count in 1...clicks { requests.append(Request(action: "click", arguments: count == 1 ? base : base.merging(["count": String(count)]) { $1 }, timeout: 10)) }
        case "move": requests = [Request(action: "move", arguments: ["x": try int("x"), "y": try int("y")], timeout: 10)]
        case "drag": requests = [Request(action: "drag", arguments: ["x": try int("x"), "y": try int("y"), "x2": try int("toX"), "y2": try int("toY")], timeout: 15)]
        case "scroll":
            var arguments = ["x": try int("x"), "y": try int("y"), "dy": try int("dy")]
            if a["dx"] != nil { arguments["dx"] = try int("dx") }
            requests = [Request(action: "scroll", arguments: arguments, timeout: 10)]
        case "type": requests = [Request(action: "type", arguments: ["text": try string("text")], timeout: 30)]
        case "key": requests = [Request(action: "key", arguments: ["key": try string("key")], timeout: 10)]
        default: throw Failure("Unknown tool: \(tool)")
        }
        for request in requests { _ = try await guest(request) }
        var content: [[String: Any]] = [["type": "text", "text": "Done: \(tool)."]]
        if a["screenshot"] as? Bool == true {
            // Give animations and redraws a moment before looking.
            try await Task.sleep(nanoseconds: 400_000_000)
            content += try await screenshot()
        }
        return content
    }

    /// A point-sized screenshot, so image pixels are the coordinates the other tools take.
    /// JPEG keeps the message small; the model sees the same detail at this size.
    private func screenshot() async throws -> [[String: Any]] {
        try requireRunning()
        let mailbox = try exchange()
        let request = Request(action: "screenshot", timeout: 15)
        let imageName = "image-\(request.id.uuidString).png"
        defer { mailbox.remove(imageName) }
        try mailbox.prepareSlot(imageName)
        let reply = try await guest(request, mailbox: mailbox)
        guard reply.values["image"] == imageName, let png = try mailbox.read(imageName, limit: 64 * 1024 * 1024),
              let source = CGImageSourceCreateWithData(png as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw Failure("The guest helper returned an invalid screenshot")
        }
        let jpeg = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(jpeg, UTType.jpeg.identifier as CFString, 1, nil) else { throw Failure("Cannot encode screenshot") }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Failure("Cannot encode screenshot") }
        return [["type": "image", "data": (jpeg as Data).base64EncodedString(), "mimeType": "image/jpeg"],
                ["type": "text", "text": "Screen: \(image.width)×\(image.height). Use these pixel coordinates."]]
    }

    private func exchange() throws -> Mailbox { try Mailbox(store.directory(name).appendingPathComponent("exchange")) }
    func guest(_ request: Request, mailbox: Mailbox? = nil) async throws -> Reply {
        let observation = ["status", "screenshot"].contains(request.action) ||
            (request.action == "app-service" && request.arguments["serviceCommand"] == "observe")
        if !observation { try outcomeGuard.requireAllowed(action: request.action) }
        try requireRunning()
        let box: Mailbox
        if let mailbox { box = mailbox } else { box = try exchange() }
        // Every mutation, including app-service bootstrap and EOF Quit/close,
        // borrows through the same durable fence as cooperative CLI calls.
        // Admission errors issue no request and do not reclassify any outcome.
        let custody = observation ? nil : try GuestInputCustody.begin(
            directory: store.directory(name), mailbox: box, request: request, claimedOwner: sessionOwner)
        guestActionInFlight = true
        defer { guestActionInFlight = false }
        do {
            if let custody { return try await custody.perform { try await box.call(request) } }
            return try await box.call(request)
        } catch {
            if let failure = error as? OutcomeFailure,
               failure.outcome == .noEffect || failure.outcome == .confirmedNoCopy {
                throw error
            }
            outcomeGuard.markUnconfirmed()
            throw error
        }
    }
    /// Running state is checked per call; existence is validated before acquiring custody.
    private func requireRunning() throws {
        guard (try? store.load(name)) != nil else {
            throw Failure("No virtual Mac named '\(name)' exists yet. Ask the user to run `terminal-mac up\(name == "default" ? "" : " " + name)`; it downloads macOS and needs them for first-time setup.")
        }
        let directory = try store.directory(name)
        guard try CLI.isRunning(directory) else { throw Failure("VM '\(name)' is stopped. Ask the user to run: terminal-mac start \(name)") }
    }
    private func explain(_ error: Error) -> String {
        if let timeout = error as? MailboxTimeout, !timeout.pickedUp {
            return "The virtual Mac has no logged-in session (it is probably at its login screen) or its guest helper is not running. Ask the user to sign in to the VM, for example with `terminal-mac view \(name)` and Ctrl+O."
        }
        return error.localizedDescription
    }

    private func send(_ message: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]) else { return }
        data.append(10)
        FileHandle.standardOutput.write(data)
    }
}
