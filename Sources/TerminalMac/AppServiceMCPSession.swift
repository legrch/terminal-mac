import Foundation
import Security
import TerminalMacCore

/// Optional application bootstrap for ONE existing stdio MCP owner. Generic
/// MCP remains unchanged when no selection is present. This controller does
/// not start the VM, execute code, create another input lease or renew custody.
@MainActor
final class AppServiceMCPSession {
    typealias Transport = (Request) async throws -> Reply

    let selection: AppMCPSelection
    let owner: String
    let directory: URL
    private(set) var session: AppMCPSession?
    private var evidence: AppServiceDirectory?
    private(set) var hasIntent = false
    private(set) var terminalPublished = false

    init(selection: AppMCPSelection, owner: String, machineDirectory: URL) {
        self.selection = selection
        self.owner = owner
        directory = machineDirectory
    }

    private static func nonce() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else { throw Failure("MCP app random identity unavailable") }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Never print or return this private session record to an MCP client.
    /// The originally minted nonce is used only on the mailbox and in
    /// owner-private descriptor-published evidence.
    private struct PrivateSession: Codable {
        let schema: String
        let runID: String
        let nonce: String
        let owner: String
        let manifestSHA256: String
        let acceptanceSHA256: String
        let helperVersion: String
        let helperBuild: String
        let appName: String
        let expiresAt: Double
        let status: String
    }

    private func publish<T: Encodable>(_ item: T, _ name: String) throws {
        guard let evidence else { throw Failure("MCP app evidence directory unavailable") }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try evidence.write(encoder.encode(item), named: name, createOnly: true)
    }

    /// Runs BEFORE allocating the first effect intent. Host APFS artifacts are
    /// private, but need not be read-only: only the LIVE VZ share admission
    /// plus guest independent VirtioFS read-only checks establish that.
    func bootstrap(host: Transport, guest: Transport) async throws {
        guard session == nil, !hasIntent else {
            throw Failure("MCP app bootstrap already attempted")
        }
        let hostStatus = try await host(Request(action: "status", timeout: 5))
        try AppMCPAdmission.host(hostStatus.values)
        let guestStatus = try await guest(Request(action: "status", timeout: 5))
        try AppMCPAdmission.guest(guestStatus.values)

        let artifacts = try AppServiceDirectory.open(
            directory.appendingPathComponent("artifacts"), privateDirectory: true)
        let staged = try artifacts.child(selection.runID)
        let (payload, rawPayload) = try AppServiceFiles.payload(
            in: staged, expectedDigest: selection.manifestSHA256)
        let accepted = try AppServiceFiles.acceptance(
            in: staged, expectedDigest: selection.acceptanceSHA256,
            payload: payload, manifestDigest: selection.manifestSHA256)
        try AppMCPAdmission.staged(rawPayload, accepted: accepted.acceptedBytes,
                                 selection: selection)

        let instance = try AppMCPSession(selection: selection, appName: payload.appName,
                                         owner: owner, nonce: Self.nonce(),
                                         helperVersion: guestStatus.values["version"]!,
                                         helperBuild: guestStatus.values["build"]!)
        // Exclusive owner-private run directory. Existing run evidence is a
        // predecessor inhibitor, not something to read/adopt/repair.
        let parent = try AppServiceDirectory.open(
            directory.appendingPathComponent("mcp-app-sessions"),
            createLeaf: true, privateDirectory: true)
        let run = try parent.child(selection.runID, create: true, exclusive: true)
        evidence = run
        session = instance
        try publish(PrivateSession(schema: AppMCPAdmission.contract,
                                   runID: selection.runID, nonce: instance.nonce,
                                   owner: owner, manifestSHA256: selection.manifestSHA256,
                                   acceptanceSHA256: selection.acceptanceSHA256,
                                   helperVersion: instance.helperVersion,
                                   helperBuild: instance.helperBuild,
                                   appName: payload.appName,
                                   expiresAt: instance.expiresAt.timeIntervalSince1970,
                                   status: "pending"), "session.json")

        // Each operation has one immutable original intent and a separate
        // readonly observation; no retries on errors, including noEffect.
        do {
            for command in ["open", "install", "launch", "activate"] {
                try await effect(command, guest: guest)
            }
            guard let session, session.isReady else {
                throw Failure("MCP app primary was not observed ready")
            }
            try session.requireInteractiveBudget()
            try publish(["schema": AppMCPAdmission.contract,
                         "state": "READY_FOR_AGENT",
                         "runID": selection.runID,
                         "helperInstance": session.helperInstance ?? "",
                         "application": session.installedApplication],
                        "ready.json")
        } catch {
            session?.markUnconfirmed()
            throw error
        }
    }

    private func effect(_ command: String, guest: Transport) async throws {
        guard var current = session else { throw Failure("MCP app session unavailable") }
        let operation = UUID().uuidString.lowercased()
        let intent = try current.prepare(command, operationID: operation)
        session = current
        hasIntent = true
        // Durable intent precedes the SINGLE mailbox request. Failure to
        // publish the intent is UNKNOWN, not permission to send/retry it.
        try publish(intent, "intent-\(intent.sequence)-\(command).json")
        let reply = try await guest(Request(action: "app-service", arguments: intent.arguments,
                                            timeout: command == "quit" ? 90 : 80))
        let receipt = try current.accept(reply.values, intent: intent)
        session = current
        try publish(receipt, "receipt-\(intent.sequence)-\(command).json")
        try await observe(receipt, guest: guest)
    }

    private func observe(_ receipt: AppMCPReceipt, guest: Transport) async throws {
        guard var current = session else { throw Failure("MCP app session unavailable") }
        // Re-observe only a positively ACKed activation while its GUI becomes
        // visible. No mutating request is repeated; each read has a new UUID.
        let until = ContinuousClock.now.advanced(by: .seconds(60))
        var index = 0
        while true {
            let uuid = UUID().uuidString.lowercased()
            let arguments = try current.observeArguments(for: receipt, observationID: uuid)
            let reply = try await guest(Request(action: "app-service", arguments: arguments, timeout: 15))
            try publish(reply.values, "observation-sample-\(receipt.sequence)-\(index).json")
            if let observation = try current.admitObservation(reply.values, for: receipt,
                                                              waitForGUI: receipt.command == "activate") {
                session = current
                try publish(observation, "observation-\(receipt.sequence)-\(receipt.command).json")
                return
            }
            guard ContinuousClock.now < until else { throw Failure("MCP app GUI observation deadline exceeded") }
            index += 1
            try await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    func requireInteractiveBudget() throws {
        guard let session else { throw Failure("MCP app session unavailable") }
        try session.requireInteractiveBudget()
    }

    /// Content-free status. The nonce is never exposed through MCP stdout.
    func summary(now: Date = Date()) -> String {
        guard let session else { return "APP_SESSION_NOT_ADMITTED" }
        let state = session.isUnconfirmed ? "UNKNOWN" :
            session.isClosed ? "CLOSED" :
            session.isReady && session.secondsRemaining(at: now) > Int(AppMCPAdmission.shutdownReserve)
                ? "READY_FOR_AGENT" : "SESSION_NOT_READY_OR_EXPIRING"
        return "Application session: \(state); remainingSeconds: \(session.secondsRemaining(at: now)); run: \(selection.runID)"
    }

    var permitsCleanRelease: Bool {
        // Before any original effect intent, no native application mutation was
        // issued by this owner. Otherwise closure must be positively observed.
        !hasIntent || (session?.isClosed == true && terminalPublished)
    }

    /// ONLY called after a clean stdio EOF. A crash, cancellation, failed
    /// publication, unknown guest effect or expired session never enters here.
    func cleanEOF(guest: Transport) async throws {
        guard let current = session, !current.isUnconfirmed, current.isReady,
              current.expiresAt > Date() else {
            throw Failure("MCP app clean Quit unavailable; retained session requires reconciliation")
        }
        // The reserve is for graceful native Quit and close, not for more GUI
        // input. Each command remains bound to this original owner and helper.
        do {
            try await effect("quit", guest: guest)
            try await effect("close", guest: guest)
            guard let ended = session, ended.isClosed,
                  let receipt = ended.lastReceipt, receipt.command == "close",
                  receipt.rootExit == "observed", receipt.primaryExit == "observed",
                  receipt.installationEvidence == "verified-at-close" else {
                throw Failure("MCP app original process exit or final tree unconfirmed")
            }
            try publish(["schema": AppMCPAdmission.contract, "state": "CLOSED",
                         "runID": selection.runID,
                         "helperInstance": ended.helperInstance ?? "",
                         "rootExit": receipt.rootExit,
                         "uiPrimaryExit": receipt.primaryExit,
                         "installationEvidence": receipt.installationEvidence],
                        "terminal.json")
            terminalPublished = true
        } catch {
            session?.markUnconfirmed()
            throw error
        }
    }
}
