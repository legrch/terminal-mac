import AppKit
import Virtualization
import TerminalMacCore

/// Explicit text transfers only; never polls or mirrors either clipboard.
@MainActor
enum ClipboardBridge {
    static func pasteRequest() throws -> Request {
        let revision = NSPasteboard.general.changeCount
        let text = NSPasteboard.general.string(forType: .string)
        return try ClipboardTransfer.pasteRequest(text, expectedRevision: revision,
                                                  currentRevision: NSPasteboard.general.changeCount)
    }
    static func paste(_ mailbox: Mailbox) async throws {
        let request = try pasteRequest()
        _ = try await mailbox.call(request)
    }
    static func copy(_ mailbox: Mailbox, request: Request? = nil, expectedHostRevision: Int? = nil) async throws {
        let revision = expectedHostRevision ?? NSPasteboard.general.changeCount
        let transfer = request ?? Request(action: "clipboard-copy", timeout: 5)
        let reply = try await mailbox.call(transfer)
        let text: String
        do {
            text = try ClipboardTransfer.copyText(reply.values["text"], expectedRevision: revision,
                                                  currentRevision: NSPasteboard.general.changeCount)
        } catch {
            // The guest transfer ended before any host clipboard write: nothing was mutated here,
            // and newer host contents were preserved.
            throw OutcomeFailure(error.localizedDescription, outcome: .confirmedNoCopy)
        }
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(text, forType: .string) else { throw OutcomeFailure("Cannot write host clipboard", outcome: .mutationUnknown) }
    }
}

@MainActor
final class ClipboardMachineView: VZVirtualMachineView {
    var clipboardMailbox: Mailbox?
    /// Returns the foreign lease owner that currently holds guest input, or nil when native
    /// window input is allowed. Wired by MachineRuntime so the window is demonstrably
    /// non-interactive while a scenario owns the lease; the holder that deliberately opened the
    /// window for owner sign-in stays interactive.
    var inputGate: (() -> String?)?
    private var transferring = false
    private var lastGateNotice = Date.distantPast
    private func denied() -> Bool {
        // A view without its runtime gate must not silently become interactive.
        let holder: String
        if let inputGate {
            guard let reason = inputGate() else { return false }
            holder = reason
        } else {
            holder = "an unavailable input gate"
        }
        if Date().timeIntervalSince(lastGateNotice) > 1 {
            lastGateNotice = Date()
            stderr("Guest input is locked by \(holder)")
        }
        NSSound.beep()
        return true
    }
    override func keyDown(with event: NSEvent) {
        if denied() { return }
        if !transfer(event) { super.keyDown(with: event) }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if denied() { return true }
        return transfer(event) || super.performKeyEquivalent(with: event)
    }
    override func mouseDown(with event: NSEvent) { if !denied() { super.mouseDown(with: event) } }
    override func rightMouseDown(with event: NSEvent) { if !denied() { super.rightMouseDown(with: event) } }
    override func otherMouseDown(with event: NSEvent) { if !denied() { super.otherMouseDown(with: event) } }
    override func mouseDragged(with event: NSEvent) { if !denied() { super.mouseDragged(with: event) } }
    override func scrollWheel(with event: NSEvent) { if !denied() { super.scrollWheel(with: event) } }
    fileprivate func transfer(_ event: NSEvent) -> Bool {
        if denied() { return true }
        let flags = event.modifierFlags
        guard let shortcut = ClipboardShortcut.resolve(keyCode: event.keyCode,
            command: flags.contains(.command), control: flags.contains(.control),
            option: flags.contains(.option), shift: flags.contains(.shift)),
              let mailbox = clipboardMailbox else {
            return false
        }
        guard !transferring else { NSSound.beep(); return true }
        let request: Request?
        do {
            request = shortcut == .paste ? try ClipboardBridge.pasteRequest() :
                shortcut == .pasteGuest ? Request(action: "key", arguments: ["key": "cmd+v"], timeout: 5) : nil
        } catch { stderr("Clipboard: \(error.localizedDescription)"); NSSound.beep(); return true }
        let revision = NSPasteboard.general.changeCount
        let copyRequest = shortcut == .copy ? Request(action: "clipboard-copy", timeout: 5) : nil
        transferring = true
        Task { @MainActor in
            defer { transferring = false }
            do {
                if let request { _ = try await mailbox.call(request) }
                else { try await ClipboardBridge.copy(mailbox, request: copyRequest, expectedHostRevision: revision) }
                stderr("Clipboard transfer completed: \(shortcut)")
            } catch { stderr("Clipboard: \(error.localizedDescription)"); NSSound.beep() }
        }
        return true
    }
}

/// Handle physical keyboard events before Virtualization's own input routing.
@MainActor
final class ClipboardMachineWindow: NSWindow {
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, let view = contentView as? ClipboardMachineView,
           let focused = firstResponder as? NSView,
           (focused === view || focused.isDescendant(of: view)), view.transfer(event) {
            return
        }
        super.sendEvent(event)
    }
}
