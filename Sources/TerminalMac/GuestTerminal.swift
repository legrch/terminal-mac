import AppKit
import ApplicationServices
import TerminalMacCore

@MainActor
extension GuestRuntime {
    /// Fixed system application only: not an arbitrary launcher or shell API.
    func terminalApplicationURL() throws -> URL {
        let url = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        guard Bundle(url: url)?.bundleIdentifier == "com.apple.Terminal" else {
            throw OutcomeFailure("TERMINAL_LAUNCH_UNAVAILABLE", outcome: .noEffect)
        }
        return url
    }

    func launchTerminal(at url: URL) async throws -> [String: String] {
        let options = NSWorkspace.OpenConfiguration()
        options.activates = true
        options.addsToRecentItems = false
        options.promptsUserIfNeeded = false
        options.allowsRunningApplicationSubstitution = false
        let application: NSRunningApplication
        do {
            application = try await NSWorkspace.shared.openApplication(at: url, configuration: options)
        } catch {
            // A lost completion cannot prove launch/activation did not occur.
            throw OutcomeFailure("TERMINAL_LAUNCH_UNCONFIRMED", outcome: .mutationUnknown)
        }
        guard application.bundleIdentifier == "com.apple.Terminal",
              application.bundleURL?.standardizedFileURL == url.standardizedFileURL,
              application.processIdentifier > 0, !application.isTerminated else {
            throw OutcomeFailure("TERMINAL_LAUNCH_UNCONFIRMED", outcome: .mutationUnknown)
        }
        return ["terminalLaunchContract": TerminalInputContract.launchVersion,
                "terminalFocusContract": TerminalInputContract.version,
                "terminalPID": String(application.processIdentifier),
                "shellReadiness": "not-proven"]
    }

    /// Refused focus always invalidates any previous target binding. A later
    /// refocus needs a fresh token, not an old one from the same window.
    private func unverifiedTerminalTarget(_ pid: Int32? = nil, foreground: Bool = false)
        -> (pid: Int32?, foreground: Bool, input: Bool, window: String?) {
        terminalWindow = nil
        terminalInputElement = nil
        terminalWindowToken = nil
        return (pid, foreground, false, nil)
    }

    /// UI focus only, not a shell-prompt claim. Never reads AXValue, titles,
    /// document paths, terminal contents or clipboard. Window tokens correlate
    /// opaque AX objects inside this helper; they are not an authentication API.
    func terminalFocusEvidence() -> (pid: Int32?, foreground: Bool, input: Bool, window: String?) {
        guard AXIsProcessTrusted(),
              let application = NSWorkspace.shared.frontmostApplication,
              application.bundleIdentifier == "com.apple.Terminal",
              application.bundleURL?.standardizedFileURL == URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app").standardizedFileURL else {
            return unverifiedTerminalTarget()
        }
        let system = AXUIElementCreateSystemWide()
        guard AXUIElementSetMessagingTimeout(system, 0.5) == .success else { return unverifiedTerminalTarget() }
        var focusedApplication: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedApplicationAttribute as CFString, &focusedApplication) == .success,
              let focusedApplication, CFGetTypeID(focusedApplication) == AXUIElementGetTypeID() else {
            return unverifiedTerminalTarget()
        }
        let appElement = focusedApplication as! AXUIElement
        var pid: pid_t = 0
        guard AXUIElementGetPid(appElement, &pid) == .success,
              pid == application.processIdentifier else { return unverifiedTerminalTarget() }
        var focusedElement: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedElement) == .success,
              let focusedElement, CFGetTypeID(focusedElement) == AXUIElementGetTypeID() else {
            return unverifiedTerminalTarget(pid, foreground: true)
        }
        let element = focusedElement as! AXUIElement
        guard AXUIElementSetMessagingTimeout(element, 0.5) == .success else { return unverifiedTerminalTarget(pid, foreground: true) }
        var elementPID: pid_t = 0
        var role: CFTypeRef?
        var windowValue: CFTypeRef?
        guard AXUIElementGetPid(element, &elementPID) == .success, elementPID == pid,
              AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
              let role, (role as? String) == (kAXTextAreaRole as String),
              AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &windowValue) == .success,
              let windowValue, CFGetTypeID(windowValue) == AXUIElementGetTypeID(),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
            return unverifiedTerminalTarget(pid, foreground: true)
        }
        let window = windowValue as! AXUIElement
        var windowPID: pid_t = 0
        guard AXUIElementGetPid(window, &windowPID) == .success, windowPID == pid else { return unverifiedTerminalTarget(pid, foreground: true) }
        // Changing the focused AX control inside the SAME window invalidates
        // the old token. No titles, terminal text or clipboard data are read.
        let sameTarget: Bool
        if let priorWindow = terminalWindow, let priorInput = terminalInputElement {
            sameTarget = CFEqual(priorWindow, window) && CFEqual(priorInput, element)
        } else {
            sameTarget = false
        }
        if !sameTarget {
            terminalWindow = window
            terminalInputElement = element
            terminalWindowToken = UUID().uuidString
        }
        return (pid, true, true, terminalWindowToken)
    }

    func requireTerminalProof(_ request: Request) throws {
        guard request.action == "terminal-key" || request.action == "terminal-type" else { return }
        let current = terminalFocusEvidence()
        try TerminalInputContract.requireFocus(proof: request.arguments["terminalProof"],
            expectedPID: request.arguments["terminalPID"], actualPID: current.pid,
            foreground: current.foreground, input: current.input,
            expectedWindow: request.arguments["terminalWindow"], actualWindow: current.window,
            key: request.arguments["key"])
    }
}
