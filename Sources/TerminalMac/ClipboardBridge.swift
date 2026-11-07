import AppKit
import Virtualization
import TerminalMacCore

/// Explicit text transfers only; never polls or mirrors either clipboard.
@MainActor
enum ClipboardBridge {
    static func paste(_ mailbox: Mailbox) async throws {
        guard let text = NSPasteboard.general.string(forType: .string), text.utf8.count <= 32768 else {
            throw Failure("Host clipboard must contain text up to 32 KiB")
        }
        _ = try await mailbox.call(Request(action: "clipboard-paste", arguments: ["text": text], timeout: 5))
    }
    static func copy(_ mailbox: Mailbox) async throws {
        let reply = try await mailbox.call(Request(action: "clipboard-copy", timeout: 5))
        guard let text = reply.values["text"], text.utf8.count <= 32768 else { throw Failure("Invalid guest clipboard reply") }
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(text, forType: .string) else { throw Failure("Cannot write host clipboard") }
    }
}

@MainActor
final class ClipboardMachineView: VZVirtualMachineView {
    var clipboardMailbox: Mailbox?
    private var transferring = false
    override func keyDown(with event: NSEvent) {
        if !transfer(event) { super.keyDown(with: event) }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        transfer(event) || super.performKeyEquivalent(with: event)
    }
    private func transfer(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command, let key = event.charactersIgnoringModifiers?.lowercased(),
              key == "v" || key == "c", let mailbox = clipboardMailbox else {
            return false
        }
        guard !transferring else { NSSound.beep(); return true }
        transferring = true
        Task { @MainActor in
            defer { transferring = false }
            do {
                if key == "v" { try await ClipboardBridge.paste(mailbox) }
                else { try await ClipboardBridge.copy(mailbox) }
            } catch { stderr("Clipboard: \(error.localizedDescription)"); NSSound.beep() }
        }
        return true
    }
}
