import AppKit
import ScreenCaptureKit
import ApplicationServices
import Darwin
import TerminalMacCore
import ServiceManagement

enum GuestGuard {
    static func requireVirtualMac() throws {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { throw Failure("Cannot verify this is a virtual Mac; guest control is disabled") }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0,
              String(cString: bytes).hasPrefix("VirtualMac") else {
            throw Failure("The guest helper only runs inside a virtual Mac. It will not control your host desktop.")
        }
    }
}

@MainActor
final class GuestRuntime: NSObject {
    let mailbox: Mailbox
    let exchange: URL
    lazy var appService = GuestAppService(exchange: exchange, mailbox: mailbox)
    var loop: Task<Void, Never>?
    var window: NSWindow?
    var label: NSTextField?
    let desktop = DesktopStream()
    var lastRequest = Date.distantPast

    let tools: URL
    var lastUpdateCheck = Date.distantPast
    // Opaque window identity for guarded input; never contains terminal text.
    var terminalWindow: AXUIElement?
    var terminalInputElement: AXUIElement?
    var terminalWindowToken: String?

    init(exchange: URL) throws {
        try GuestGuard.requireVirtualMac()
        self.exchange = exchange
        tools = exchange.deletingLastPathComponent().appendingPathComponent("tools")
        mailbox = try Mailbox(exchange)
        super.init()
    }
    func start() {
        GuestBootstrap.registerForGuestLogin()
        NSApp.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 300), styleMask: [.titled, .miniaturizable], backing: .buffered, defer: false)
        window.title = "terminal-mac guest helper"
        let title = NSTextField(labelWithString: "This virtual Mac is ready for your agent.")
        title.font = .systemFont(ofSize: 19, weight: .semibold)
        let description = NSTextField(wrappingLabelWithString: "Allow Screen Recording and Accessibility inside this VM. Keep this helper running in your logged-in guest desktop. Your physical Mac is not controlled.")
        let status = NSTextField(wrappingLabelWithString: permissionStatus)
        let capture = NSButton(title: "Allow Screen Recording", target: self, action: #selector(screenPermission))
        let accessibility = NSButton(title: "Allow Accessibility", target: self, action: #selector(accessibilityPermission))
        let buttons = NSStackView(views: [capture, accessibility]); buttons.orientation = .horizontal
        let login = NSButton(title: "Guest Login Items…", target: self, action: #selector(loginSettings))
        let stack = NSStackView(views: [title, description, status, buttons, login])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24)
        ])
        self.window = window; self.label = status
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        loop = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                self.label?.stringValue = self.permissionStatus
                do {
                    for request in try mailbox.requests() {
                        lastRequest = Date()
                        // Live frames long-poll for changes; input must never wait behind them.
                        if request.arguments["format"] == "bgra-lz4" { Task { await self.handle(request) } }
                        else { await handle(request) }
                    }
                } catch { stderr(error.localizedDescription) }
                desktop.stopIfIdle()
                if Date().timeIntervalSince(lastUpdateCheck) > 30 {
                    lastUpdateCheck = Date()
                    // A scenario that owns guest input may be mid-run; never replace the helper
                    // beneath it.
                    // An expired/invalid marker is evidence of possible crashed or unresolved
                    // work, never proof that the host lease ended. Defer until explicit recovery.
                    if !appService.blocksHelperUpdate && mailbox.helperUpdateDisposition().mayUpdate {
                        GuestBootstrap.updateFromSharedTools(tools)
                    }
                }
                // Poll quickly while a viewer or agent is active, and gently when idle.
                try? await Task.sleep(nanoseconds: Date().timeIntervalSince(lastRequest) < 3 ? 3_000_000 : 40_000_000)
            }
        }
    }
    var permissionStatus: String {
        "Screen Recording: \(CGPreflightScreenCaptureAccess() ? "allowed" : "needed")   ·   Accessibility: \(AXIsProcessTrusted() ? "allowed" : "needed")"
    }
    @objc func screenPermission() {
        CGRequestScreenCaptureAccess()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }
    @objc func accessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
    @objc func loginSettings() { SMAppService.openSystemSettingsLoginItems() }
    func handle(_ request: Request) async {
        // Provenance for the failure reply: anything after the first guest effect must be
        // treated as if the effect may have happened, unless a specific confirmed outcome applies.
        var effects = InputEffectProgress()
        do {
            try GuestGuard.requireVirtualMac()
            try request.requireLive()
            var values: [String: String] = [:]
            if request.arguments["terminalProof"] != nil || request.arguments["terminalPID"] != nil || request.arguments["terminalWindow"] != nil || ["terminal-key", "terminal-type"].contains(request.action) {
                let wire = try TerminalInputContract.wireAction(request.action,
                    proof: request.arguments["terminalProof"], pid: request.arguments["terminalPID"],
                    window: request.arguments["terminalWindow"], key: request.arguments["key"])
                guard wire == request.action else { throw OutcomeFailure("TERMINAL_GUARD_INVALID", outcome: .noEffect) }
            }
            switch request.action {
            case "app-service":
                values = try await appService.handle(request)
                // A response-slot failure after a committed service operation
                // cannot be reported as noEffect. Its private receipt remains.
                effects.begin()
            case "terminal-open":
                guard request.arguments.isEmpty else { throw OutcomeFailure("TERMINAL_GUARD_INVALID", outcome: .noEffect) }
                try requireAccessibility()
                let applicationURL = try terminalApplicationURL()
                try request.requireLive()
                effects.begin()
                values = try await launchTerminal(at: applicationURL)
            case "clipboard-paste":
                try requireAccessibility()
                guard let text = request.arguments["text"], text.utf8.count <= 32768 else {
                    throw OutcomeFailure("Clipboard text exceeds 32 KiB", outcome: .noEffect)
                }
                effects.begin()
                NSPasteboard.general.clearContents()
                guard NSPasteboard.general.setString(text, forType: .string) else { throw Failure("Cannot write guest clipboard") }
                try press("cmd+v")
            case "clipboard-copy":
                try requireAccessibility()
                let before = NSPasteboard.general.changeCount
                try press("cmd+c", beforeEvent: { effects.begin() })
                let deadline = Date().addingTimeInterval(2)
                while NSPasteboard.general.changeCount == before, Date() < deadline {
                    try await Task.sleep(nanoseconds: 20_000_000)
                }
                guard NSPasteboard.general.changeCount != before else {
                    throw OutcomeFailure("Nothing copied in guest; host clipboard unchanged", outcome: .confirmedNoCopy)
                }
                do { values["text"] = try ClipboardTransfer.guestCopyText(NSPasteboard.general.string(forType: .string)) }
                catch { throw OutcomeFailure(error.localizedDescription, outcome: .confirmedNoCopy) }
            case "status":
                let bounds = CGDisplayBounds(CGMainDisplayID())
                let terminal = terminalFocusEvidence()
                values = ["screenRecording": String(CGPreflightScreenCaptureAccess()), "accessibility": String(AXIsProcessTrusted()),
                          "width": String(Int(bounds.width)), "height": String(Int(bounds.height)),
                          "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.2.0",
                          "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
                          "terminalFocusContract": TerminalInputContract.version,
                          "terminalLaunchContract": TerminalInputContract.launchVersion,
                          "terminalForeground": String(terminal.foreground), "terminalInput": String(terminal.input),
                          "terminalPID": terminal.pid.map { String($0) } ?? "", "terminalWindow": terminal.window ?? "",
                          "shellReadiness": "not-proven",
                          "appServiceContract": AppServiceContract.version,
                          "appServiceExecutor": "compiled-native-helper",
                          "appServiceLaunchIdentityContract": AppLaunchIdentity.contract,
                          "appServiceAdmission": appService.blocksHelperUpdate ? "active-or-unresolved" : "available"]
            case "screenshot" where request.arguments["format"] == "bgra-lz4":
                guard CGPreflightScreenCaptureAccess() else { throw Failure("Allow Screen Recording for TerminalMacGuest inside the VM, then reopen the helper if macOS requests it") }
                try await desktop.prepare(maxWidth: number(request, "maxWidth", range: 16...7680), maxHeight: number(request, "maxHeight", range: 16...4320))
                let since = Int(request.arguments["since"] ?? "") ?? -1
                let wait = Double(min(1000, max(0, Int(request.arguments["wait"] ?? "0") ?? 0))) / 1000
                let bounds = CGDisplayBounds(CGMainDisplayID())
                values = ["pointWidth": String(Int(bounds.width)), "pointHeight": String(Int(bounds.height))]
                guard let frame = try await desktop.frame(after: since, timeout: wait) else { values["unchanged"] = "true"; break }
                let encoded = try DesktopStream.encode(frame)
                let filename = "image-\(request.id.uuidString).bin"
                try mailbox.publish(encoded.data, into: filename)
                values.merge(["image": filename, "format": "bgra-lz4", "width": String(encoded.width), "height": String(encoded.height),
                              "bytesPerRow": String(encoded.bytesPerRow), "sequence": String(frame.sequence)]) { $1 }
            case "screenshot", "snapshot":
                guard CGPreflightScreenCaptureAccess() else { throw Failure("Allow Screen Recording for TerminalMacGuest inside the VM, then reopen the helper if macOS requests it") }
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else { throw Failure("No guest display is available") }
                let bounds = CGDisplayBounds(display.displayID)
                let config = SCStreamConfiguration()
                config.width = Int(bounds.width); config.height = Int(bounds.height)
                config.showsCursor = true
                let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, excludingWindows: []), configuration: config)
                guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw Failure("Cannot encode guest screenshot") }
                let filename = "image-\(request.id.uuidString).png"
                try mailbox.publish(png, into: filename)
                values = ["image": filename, "width": String(image.width), "height": String(image.height)]
            case "click", "move":
                try requireAccessibility()
                let point = try coordinates(request)
                let right = request.arguments["button"] == "right"
                let button: CGMouseButton = right ? .right : .left
                if request.action == "move" {
                    effects.begin()
                    try postMouse(.mouseMoved, point: point, button: button)
                }
                else {
                    // `count` continues a multi-click the viewer already started, so a double click is two requests.
                    let count = try number(request, "count", fallback: 1, range: 1...3)
                    let clicks = request.arguments["double"] == "true" ? 1...2 : count...count
                    effects.begin()
                    for n in clicks {
                        try postMouse(right ? .rightMouseDown : .leftMouseDown, point: point, button: button, count: n)
                        try postMouse(right ? .rightMouseUp : .leftMouseUp, point: point, button: button, count: n)
                    }
                }
            case "drag":
                try requireAccessibility()
                let start = try coordinates(request)
                let end = try coordinates(request, x: "x2", y: "y2")
                effects.begin()
                try postMouse(.leftMouseDown, point: start, button: .left)
                let steps = max(2, min(30, Int(hypot(end.x - start.x, end.y - start.y) / 12)))
                for step in 1...steps {
                    let t = Double(step) / Double(steps)
                    try postMouse(.leftMouseDragged, point: CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t), button: .left)
                    try await Task.sleep(nanoseconds: 8_000_000)
                }
                try postMouse(.leftMouseUp, point: end, button: .left)
            case "scroll":
                try requireAccessibility()
                if request.arguments["x"] != nil {
                    effects.begin()
                    try postMouse(.mouseMoved, point: coordinates(request), button: .left)
                }
                let dy = try number(request, "dy", range: -1000...1000)
                let dx = Int(request.arguments["dx"] ?? "0") ?? 0
                guard (-1000...1000).contains(dx), let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0) else { throw Failure("Invalid scroll") }
                effects.begin()
                event.post(tap: .cghidEventTap)
            case "type", "terminal-type":
                try requireAccessibility()
                guard let text = request.arguments["text"], text.utf8.count <= 32768 else { throw OutcomeFailure("Provide text (maximum 32 KiB)", outcome: .noEffect) }
                // Unicode events avoid modifying the guest or host clipboard.
                var chunk: [UniChar] = []
                func send() throws {
                    guard !chunk.isEmpty else { return }
                    guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                          let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else { throw Failure("Cannot create keyboard event") }
                    // Literal text must not inherit modifiers from a preceding shortcut.
                    down.flags = []; up.flags = []
                    chunk.withUnsafeBufferPointer { ptr in down.keyboardSetUnicodeString(stringLength: ptr.count, unicodeString: ptr.baseAddress!) }
                    down.flags = []; up.flags = []
                    // Re-evaluate the bound Terminal target for every chunk.
                    // A later refusal cannot reclassify earlier chunks as noEffect.
                    try effects.perform(check: {
                        try request.requireLive()
                        try self.requireTerminalProof(request)
                        // AX queries are synchronous and bounded individually, but can
                        // still cross the request deadline. Recheck immediately before
                        // publishing any keyboard event.
                        try Task.checkCancellation()
                        try request.requireLive()
                    }, effect: {
                        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
                    })
                    chunk.removeAll(keepingCapacity: true)
                }
                for character in text {
                    let units = Array(String(character).utf16)
                    if chunk.count + units.count > 16 { try send() }
                    chunk += units
                }
                try send()
            case "key", "terminal-key":
                try requireAccessibility()
                try press(request.arguments["key"] ?? "", beforeEvent: {
                    try request.requireLive()
                    try self.requireTerminalProof(request)
                    try Task.checkCancellation()
                    try request.requireLive()
                    effects.begin()
                })
            default: throw OutcomeFailure("Unknown guest action: \(request.action)", outcome: .noEffect)
            }
            try mailbox.respond(Reply(id: request.id, values: values))
        } catch {
            let outcome = effects.outcome(for: error)
            try? mailbox.respond(Reply(id: request.id, values: (error as? OutcomeFailure)?.values ?? [:],
                                       error: error.localizedDescription, outcome: outcome))
        }
    }
    func requireAccessibility() throws {
        guard AXIsProcessTrusted() else { throw Failure("Allow Accessibility for TerminalMacGuest inside the VM") }
    }
    func number(_ request: Request, _ key: String, fallback: Int? = nil, range: ClosedRange<Int>) throws -> Int {
        if request.arguments[key] == nil, let fallback { return fallback }
        guard let raw = request.arguments[key], let value = Int(raw), range.contains(value) else { throw Failure("Invalid \(key); expected \(range)") }
        return value
    }
    func coordinates(_ request: Request, x: String = "x", y: String = "y") throws -> CGPoint {
        let bounds = CGDisplayBounds(CGMainDisplayID())
        return CGPoint(x: try number(request, x, range: 0...(Int(bounds.width) - 1)), y: try number(request, y, range: 0...(Int(bounds.height) - 1)))
    }
    func postMouse(_ type: CGEventType, point: CGPoint, button: CGMouseButton, count: Int = 1) throws {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button) else { throw Failure("Cannot create mouse event") }
        event.setIntegerValueField(.mouseEventClickState, value: Int64(count))
        event.post(tap: .cghidEventTap)
    }
    func press(_ chord: String, beforeEvent: () throws -> Void = {}) throws {
        let parts = chord.lowercased().split(separator: "+").map(String.init)
        guard let key = parts.last, let code = Self.keys[key] else { throw Failure("Unknown key: \(chord). Example: cmd+space, return, ctrl+a") }
        var flags: CGEventFlags = []
        for modifier in parts.dropLast() {
            switch modifier {
            case "cmd", "command": flags.insert(.maskCommand)
            case "ctrl", "control": flags.insert(.maskControl)
            case "alt", "option": flags.insert(.maskAlternate)
            case "shift": flags.insert(.maskShift)
            default: throw Failure("Unknown modifier: \(modifier)")
            }
        }
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { throw Failure("Cannot create key") }
            event.flags = down ? flags : []
            try beforeEvent()
            event.post(tap: .cghidEventTap)
        }
    }
    static let keys: [String: CGKeyCode] = [
        "a":0,"s":1,"d":2,"f":3,"h":4,"g":5,"z":6,"x":7,"c":8,"v":9,"b":11,"q":12,"w":13,"e":14,"r":15,"y":16,"t":17,
        "1":18,"2":19,"3":20,"4":21,"6":22,"5":23,"=":24,"9":25,"7":26,"-":27,"8":28,"0":29,
        "]":30,"o":31,"u":32,"[":33,"i":34,"p":35,"return":36,"enter":36,"l":37,"j":38,"'":39,"k":40,";":41,"\\":42,",":43,"/":44,"n":45,"m":46,".":47,
        "tab":48,"space":49,"backspace":51,"escape":53,"esc":53,"home":115,"pageup":116,"delete":117,"end":119,"pagedown":121,
        "left":123,"right":124,"down":125,"up":126,"f1":122,"f2":120,"f3":99,"f4":118,"f5":96,"f6":97,"f7":98,"f8":100,"f9":101,"f10":109,"f11":103,"f12":111
    ]
}
