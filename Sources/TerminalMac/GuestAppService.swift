import AppKit
import ApplicationServices
import Darwin
import TerminalMacCore

/// The test server is this compiled helper object, not host-supplied guest.sh.
/// Only an explicitly selected application payload is accepted. There is no
/// shell, script, command line, environment override or external server child.
@MainActor
final class GuestAppService {
    static var rootURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/terminal-mac-app-service")
    }
    let instance = UUID().uuidString.lowercased()
    let exchange: URL
    let mailbox: Mailbox
    private var record: AppServiceRecord?
    private var liveTimebase: AppServiceTimebase?
    private var liveStart: ContinuousClock.Instant?
    private var payload: AppServicePayload?
    private var policy: AppVerificationPolicy?
    private var runDirectory: AppServiceDirectory?
    private var stageDirectory: AppServiceDirectory?
    private var lock: AppServiceLock?
    private var lifecycle: GuestApplicationLifecycle?
    private var installedURL: URL?
    private var launchEvidencePublication = "not-attempted"


    init(exchange: URL, mailbox: Mailbox) { self.exchange = exchange; self.mailbox = mailbox }
    var blocksHelperUpdate: Bool {
        (record != nil && record?.phase != "closed") || AppServiceFiles.hasUnresolved(in: Self.rootURL)
    }
    private func check(_ request: Request, owner: String) throws {
        try GuestGuard.requireVirtualMac()
        try Task.checkCancellation()
        try request.requireLive()
        guard case .active(let actual) = mailbox.helperUpdateDisposition(), actual == owner else {
            throw AppServiceContract.refuse("APP_SERVICE_CUSTODY")
        }
    }
    private func liveNow() throws -> Date {
        guard let liveStart, var clock = liveTimebase else {
            throw AppServiceContract.refuse("APP_SERVICE_UNRESOLVED")
        }
        let elapsed = liveStart.duration(to: ContinuousClock.now).components
        let value = try clock.sample(elapsed: Double(elapsed.seconds) +
                                     Double(elapsed.attoseconds) / 1e18)
        liveTimebase = clock
        return value
    }
    private func store(_ value: AppServiceRecord, initial: Bool = false) throws {
        guard let runDirectory else { throw AppServiceContract.refuse("APP_SERVICE_UNRESOLVED") }
        try value.validate()
        try runDirectory.write(JSONEncoder().encode(value), named: "state.json", createOnly: initial)
    }
    private func finish(_ value: AppServiceRecord) throws {
        guard let runDirectory else { throw AppServiceContract.refuse("APP_SERVICE_UNRESOLVED") }
        try value.validate()
        // Immutable operation receipt first; terminal state publication second.
        // Any failure freezes this service without deleting possible evidence.
        try runDirectory.write(JSONEncoder().encode(value), named: "receipt-" + value.operationID + ".json", createOnly: true)
        try store(value)
        record = value
    }
    private func requireValidInstalledSignature(at url: URL, request: Request, command: AppServiceCommand) throws {
        guard let payload, let policy else { throw AppServiceContract.refuse("APP_SERVICE_UNRESOLVED") }
        try AppSignatureVerifier.verify(at: url, payload: payload, policy: policy) {
            try self.check(request, owner: command.owner)
        }
    }

    private func applicationIdentity(at url: URL, payload: AppServicePayload) throws {
        let app = try AppServiceDirectory.open(url)
        let contents = try app.child("Contents")
        guard let data = try contents.read("Info.plist", limit: 65536),
              let info = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == payload.bundleID,
              info["CFBundleShortVersionString"] as? String == payload.version,
              let executable = info["CFBundleExecutable"] as? String,
              AppServiceContract.path(executable), !executable.contains("/"),
              payload.entries.contains(where: { $0.path == "Contents/MacOS/" + executable && $0.kind == "file" && $0.mode & 0o111 != 0 }) else {
            throw AppServiceContract.refuse("APP_SERVICE_APP_IDENTITY")
        }
    }
    private func ownedApplication() throws -> NSRunningApplication {
        guard let lifecycle, let pid = record?.appPID else {
            throw AppServiceContract.refuse("APP_SERVICE_APP_IDENTITY")
        }
        let primary = try lifecycle.requireLive()
        guard primary.processIdentifier == pid else { throw AppLaunchIdentityError.changedIdentity }
        return primary
    }

    /// Immutable bounded metadata, separate from state.json and the original
    /// action receipt. No argv, environment, application text or credentials.
    private func retainLaunchEvidence(_ phase: String, command: AppServiceCommand) throws {
        guard ["returned", "resolution", "lifecycle"].contains(phase), let runDirectory,
              let lifecycle, let record else { throw AppServiceContract.refuse("APP_SERVICE_UNRESOLVED") }
        var evidence = lifecycle.diagnosticValues()
        evidence["schema"] = "terminal-mac.launch-evidence/1"
        evidence["runId"] = record.runID
        evidence["manifestSHA256"] = record.manifestSHA256
        evidence["acceptanceSHA256"] = record.acceptanceSHA256
        evidence["helperInstance"] = record.helperInstance
        evidence["serviceOperationId"] = command.operationID
        evidence["serviceSequence"] = String(command.sequence)
        launchEvidencePublication = "unconfirmed"
        try runDirectory.write(JSONEncoder().encode(evidence),
            named: "launch-" + phase + "-" + command.operationID + ".json", createOnly: true)
        launchEvidencePublication = "durable-" + phase
    }

    /// A restart exposes retained diagnostics but cannot adopt old PIDs, restore
    /// kernel exit observers, or turn pending publication into launch authority.
    private func retainedLaunchEvidence(in run: AppServiceDirectory, record: AppServiceRecord) -> [String: String] {
        let keys: Set<String> = ["launchIdentityContract", "launchIdentityState", "launchIdentityReason",
            "returnedPID", "returnedExecutable", "returnedBundle", "returnedKernelExecutable",
            "returnedStartIdentity", "returnedBundleIdentifier", "launchRootPID", "launchRootStartIdentity",
            "launchRootExecutable", "uiPrimaryPID", "uiPrimaryStartIdentity", "uiPrimaryExecutable",
            "uiPrimaryBundleIdentifier", "launchRootEqualsPrimary", "acceptedDescendantsAtBinding",
            "launchAncestry", "uiPrimaryParentPID", "launchRootParentPID", "acceptedDescendantIdentities",
            "descendantIdentitiesTruncated", "normalQuitRequested"]
        do {
            for operation in record.operations.reversed() {
                for phase in ["lifecycle", "resolution", "returned"] {
                    guard let bytes = try run.read("launch-" + phase + "-" + operation + ".json", limit: 65536) else { continue }
                    let data = try JSONDecoder().decode([String: String].self, from: bytes)
                    guard data["schema"] == "terminal-mac.launch-evidence/1", data["runId"] == record.runID,
                          data["manifestSHA256"] == record.manifestSHA256,
                          data["acceptanceSHA256"] == record.acceptanceSHA256,
                          data["helperInstance"] == record.helperInstance,
                          data["serviceOperationId"] == operation,
                          data["serviceSequence"] == record.operations.firstIndex(of: operation).map(String.init),
                          data.values.allSatisfy({ $0.utf8.count <= 2048 && !$0.contains("\0") && !$0.contains("\n") }) else {
                        return ["launchEvidenceRead": "invalid"]
                    }
                    var output = data.filter { keys.contains($0.key) }
                    output["launchEvidenceRead"] = "retained-metadata-only"
                    output["launchEvidenceOperationId"] = operation
                    output["launchIdentityState"] = "retained-unconfirmed"
                    output["rootExit"] = "unconfirmed"
                    output["uiPrimaryExit"] = "unconfirmed"
                    output["applicationRunning"] = "unconfirmed"
                    return output
                }
            }
            return ["launchEvidenceRead": "absent"]
        } catch { return ["launchEvidenceRead": "unavailable"] }
    }
    private func values(_ value: AppServiceRecord, restored: Bool = false) -> [String: String] {
        var result: [String: String] = [
            "serviceContract": AppServiceContract.version,
            "executor": "compiled-native-helper", "serverCodeSource": "helper-binary",
            "runId": value.runID, "nonce": value.nonce,
            "manifestSHA256": value.manifestSHA256, "acceptanceSHA256": value.acceptanceSHA256, "helperInstance": value.helperInstance,
            "operationId": value.operationID, "sequence": String(value.sequence),
            "state": restored && value.phase != "closed" ? "unknown" : value.phase,
            "pending": value.pending ?? "", "serviceReady": String(!restored && value.phase != "unknown" && value.pending == nil && value.phase != "closed"),
            "restoredObservation": String(restored), "helperPID": String(getpid()),
            "applicationPID": value.appPID.map(String.init) ?? "",
            "applicationRunning": "unconfirmed", "windows": "unconfirmed",
            "rootExit": "unconfirmed", "descendantCleanup": "unverified",
            "expiryIsCompletion": "false", "shell": "not-used",
            // The fixed path and evidence level are guest-local observations.
            // "verified-at-install" is not an assertion about later mutations.
            "installationRoot": AppServiceContract.installationRoot,
            "installationLocation": AppServiceContract.installationLocation,
            "installedApplication": installedURL?.path ?? "",
            "installationEvidence": installedURL == nil ? "not-installed" :
                (value.phase == "closed" ? "verified-at-close" : "verified-at-install")
        ]
        result["launchEvidencePublication"] = launchEvidencePublication
        if !restored, let lifecycle {
            result.merge(lifecycle.diagnosticValues()) { _, observed in observed }
            if value.phase == "running" {
                do {
                    let primary = try ownedApplication()
                    result["foreground"] = String(NSWorkspace.shared.frontmostApplication?.processIdentifier == primary.processIdentifier)
                    if AXIsProcessTrusted() {
                        let element = AXUIElementCreateApplication(primary.processIdentifier)
                        if AXUIElementSetMessagingTimeout(element, 0.5) == .success {
                            var windows: CFTypeRef?
                            if AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &windows) == .success,
                               let count = (windows as? [Any])?.count, count <= 64 {
                                result["windows"] = String(count)
                            }
                        }
                    }
                } catch {
                    result["serviceReady"] = "false"
                    result["launchIdentityState"] = "unknown"
                    result["foreground"] = "unconfirmed"
                    result["windows"] = "unconfirmed"
                }
            } else if result["uiPrimaryExit"] == "observed" { result["windows"] = "0" }
        } else if !restored && value.appPID == nil && ["ready", "installed", "closed"].contains(value.phase) {
            result["applicationRunning"] = "false"; result["windows"] = "0"
            result["rootExit"] = "no-owned-root"
        }
        return result
    }
    private func observe(_ command: AppServiceCommand) throws -> [String: String] {
        if let record, record.runID == command.runID {
            try record.requireBinding(command)
            return values(record)
        }
        let root = try AppServiceDirectory.open(Self.rootURL, privateDirectory: true)
        let run = try root.child(command.runID)
        guard let data = try run.read("state.json", limit: 65536) else { throw AppServiceContract.refuse("APP_SERVICE_UNRESOLVED") }
        let prior = try JSONDecoder().decode(AppServiceRecord.self, from: data)
        try prior.requireBinding(command)
        // No adoption, child reconstruction, lease renewal or replay on restart.
        var observed = values(prior, restored: true)
        observed.merge(retainedLaunchEvidence(in: run, record: prior)) { _, diagnostic in diagnostic }
        return observed
    }

    func handle(_ request: Request) async throws -> [String: String] {
        try GuestGuard.requireVirtualMac()
        let command = try AppServiceCommand(arguments: request.arguments)
        try request.requireLive()
        if command.command == "observe" { return try observe(command) }
        try check(request, owner: command.owner)
        var effectStarted = false
        var launchResolutionAttempted = false
        do {
            if command.command == "open" {
                guard record == nil || record?.phase == "closed" else { throw AppServiceContract.refuse("APP_SERVICE_BUSY") }
                // Resolve every shared component without following links. The
                // guest must see a read-only artifacts mount, never host code.
                let share = try AppServiceDirectory.open(exchange.deletingLastPathComponent())
                let artifacts = try share.child("artifacts")
                try artifacts.requireReadOnlyVolume()
                let stage = try artifacts.child(command.runID)
                let (selected, manifestBytes) = try AppServiceFiles.payload(in: stage, expectedDigest: command.manifestSHA256)
                let acceptance = try AppServiceFiles.acceptance(in: stage,
                    expectedDigest: command.acceptanceSHA256, payload: selected,
                    manifestDigest: command.manifestSHA256)
                // An existing guest /Applications/Farol.app belongs to a
                // previous installation. Refuse it BEFORE creating service
                // state; no uninstall, replacement or privilege escalation.
                try AppServiceFiles.requireGuestApplicationsAvailable(selected)
                try check(request, owner: command.owner)
                effectStarted = true
                let root = try AppServiceDirectory.open(Self.rootURL, createLeaf: true, privateDirectory: true)
                let held = try root.lock()
                guard !AppServiceFiles.hasUnresolved(in: Self.rootURL) else { throw AppServiceContract.refuse("APP_SERVICE_UNRESOLVED") }
                let directory = try root.child(command.runID, create: true, exclusive: true)
                lock = held; runDirectory = directory; stageDirectory = stage; payload = selected; policy = acceptance.policy
                lifecycle = nil; installedURL = nil; launchEvidencePublication = "not-attempted"
                liveStart = ContinuousClock.now
                liveTimebase = try AppServiceTimebase(wallAnchor: Date())
                var next = try AppServiceRecord(open: command, helperInstance: instance, now: liveNow())
                record = next
                try directory.write(manifestBytes, named: "payload.json", createOnly: true)
                try directory.write(acceptance.acceptedBytes, named: "accepted-application.json", createOnly: true)
                try directory.write(acceptance.policyBytes, named: "verification-policy.json", createOnly: true)
                try store(next, initial: true)
                try next.complete("open")
                try finish(next)
                return values(next)
            }
            guard var next = record, let payload, let stageDirectory,
                  next.helperInstance == instance else { throw AppServiceContract.refuse("APP_SERVICE_UNRESOLVED") }
            // Begin is the same pure transition exercised by the Core tests.
            try next.begin(command, now: liveNow(), activeOwner: command.owner)
            try check(request, owner: command.owner)
            // Known launch refusal happens before the durable dispatch intent
            // and before LaunchServices. It does not replace an installed app,
            // acquire a process by name, or overwrite a prior launch receipt.
            var launchPlan: AppLaunchPlan?
            var launchBaseline: AppProcessCensus?
            if command.command == "launch" {
                guard let installedURL else { throw AppServiceContract.refuse("APP_SERVICE_NOT_INSTALLED") }
                try AppServiceFiles.verifyInstalled(payload, in: AppServiceDirectory.open(installedURL)) {
                    try self.check(request, owner: command.owner)
                }
                try applicationIdentity(at: installedURL, payload: payload)
                try requireValidInstalledSignature(at: installedURL, request: request, command: command)
                let tree = try AppServiceDirectory.open(installedURL)
                let plan = try AppLaunchPlan(installedPath: installedURL.path, payload: payload) { relative, limit in
                    let (parent, leaf) = try tree.parent(of: relative)
                    guard let data = try parent.read(leaf, limit: limit) else { throw AppLaunchIdentityError.invalidPlan }
                    return data
                }
                let before = try GuestProcessCensus.capture()
                try AppLaunchIdentity.preflight(plan: plan, census: before)
                launchPlan = plan; launchBaseline = before
                try check(request, owner: command.owner)
                // A new launch must never label a previous clean lifetime's
                // returned PID as evidence for this new operation. Immutable
                // prior receipts remain on disk; clear only the live reference.
                lifecycle = nil; launchEvidencePublication = "not-attempted"
            }
            effectStarted = true; record = next
            try store(next)
            switch command.command {
            case "install":
                // Revalidate the manifest and blobs before guest /Applications
                // install. The root is fixed in this helper; no staged script,
                // host path, sudo or privileged installer.
                // Existing Farol.app is never replaced or deleted.
                _ = try AppServiceFiles.payload(in: stageDirectory, expectedDigest: command.manifestSHA256)
                let url = try AppServiceFiles.installInGuestApplications(payload, from: stageDirectory, check: {
                    try self.check(request, owner: command.owner)
                }, verify: { candidate in
                    try self.applicationIdentity(at: candidate, payload: payload)
                    try self.requireValidInstalledSignature(at: candidate, request: request, command: command)
                })
                guard url.standardizedFileURL.path == AppServiceContract.installationRoot + "/" + payload.appName else {
                    throw AppServiceContract.refuse("APP_SERVICE_UNSAFE_PATH")
                }
                try applicationIdentity(at: url, payload: payload)
                try AppServiceFiles.verifyInstalled(payload, in: AppServiceDirectory.open(url)) {
                    try self.check(request, owner: command.owner)
                }
                try requireValidInstalledSignature(at: url, request: request, command: command)
                installedURL = url
                try next.complete("install")
            case "launch":
                guard let installedURL else { throw AppServiceContract.refuse("APP_SERVICE_NOT_INSTALLED") }
                guard let launchPlan, let launchBaseline else { throw AppLaunchIdentityError.invalidPlan }
                try check(request, owner: command.owner)
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                configuration.addsToRecentItems = false
                configuration.promptsUserIfNeeded = false
                configuration.allowsRunningApplicationSubstitution = false
                configuration.createsNewApplicationInstance = true
                let attempt = GuestApplicationLifecycle(plan: launchPlan, before: launchBaseline,
                    notBefore: try GuestProcessCensus.timeBoundary())
                lifecycle = attempt; launchEvidencePublication = "not-attempted"
                let launched: NSRunningApplication
                do { launched = try await NSWorkspace.shared.openApplication(at: installedURL, configuration: configuration) }
                catch { throw AppServiceContract.refuse("APP_SERVICE_LAUNCH_UNKNOWN") }
                // Return metadata is retained even when the returned application
                // is a launcher, a nested bundle or ultimately unadmissible.
                attempt.receive(launched)
                try retainLaunchEvidence("returned", command: command)
                try await attempt.qualify { try self.check(request, owner: command.owner) }
                let primary = try attempt.requireLive()
                try check(request, owner: command.owner)
                launchResolutionAttempted = true
                try retainLaunchEvidence("resolution", command: command)
                try next.complete("launch", pid: primary.processIdentifier)
            case "activate":
                let app = try ownedApplication()
                guard !app.isTerminated else { throw AppServiceContract.refuse("APP_SERVICE_NOT_RUNNING") }
                try check(request, owner: command.owner)
                guard app.activate(options: [.activateAllWindows]) else {
                    throw AppServiceContract.refuse("APP_SERVICE_LAUNCH_UNKNOWN")
                }
                try next.complete("activate", pid: app.processIdentifier)
            case "quit":
                guard let lifecycle else { throw AppServiceContract.refuse("APP_SERVICE_QUIT_UNKNOWN") }
                try await lifecycle.quit { try self.check(request, owner: command.owner) }
                try retainLaunchEvidence("lifecycle", command: command)
                try next.complete("quit")
            case "close":
                if let lifecycle {
                    try lifecycle.requireExited { try self.check(request, owner: command.owner) }
                    try retainLaunchEvidence("lifecycle", command: command)
                }
                // Verify the installed application tree again after Quit.
                // Closure retains /Applications and private receipts; it never
                // removes the app, weakens TCC or silently repairs it.
                if let installedURL {
                    try AppServiceFiles.verifyInstalled(payload, in: AppServiceDirectory.open(installedURL)) {
                        try self.check(request, owner: command.owner)
                    }
                    try applicationIdentity(at: installedURL, payload: payload)
                    try requireValidInstalledSignature(at: installedURL, request: request, command: command)
                }
                try next.complete("close")
            default: throw AppServiceContract.refuse("APP_SERVICE_INVALID")
            }
            try finish(next)
            let result = values(next)
            if command.command == "close" { lock = nil }
            return result
        } catch {
            if effectStarted {
                if ["launch", "activate", "quit", "close"].contains(command.command) { lifecycle?.note(error) }
                if command.command == "launch", lifecycle != nil {
                    // At most one final diagnostic publication. A failed write
                    // is not replayed, and does not erase returned metadata.
                    if !launchResolutionAttempted && launchEvidencePublication != "unconfirmed" {
                        launchResolutionAttempted = true
                        try? retainLaunchEvidence("resolution", command: command)
                    }
                }
                // Do not retry a failed state publication, rollback a partial
                // install, force-quit an app, or remove predecessor evidence.
                record?.markUnknown()
                let identityReason = command.command == "quit" || command.command == "close" ? "APP_SERVICE_QUIT_UNKNOWN" : "APP_SERVICE_LAUNCH_UNKNOWN"
                let reason = (error as? OutcomeFailure)?.message ?? (error is AppLaunchIdentityError ? identityReason : "APP_SERVICE_IO")
                throw OutcomeFailure(AppServiceContract.reasons.contains(reason) ? reason : "APP_SERVICE_IO", outcome: .mutationUnknown)
            }
            let reason = (error as? OutcomeFailure)?.message ??
                ((error as? AppLaunchIdentityError) == .preexisting ? "APP_SERVICE_RUNNING" :
                 error is AppLaunchIdentityError ? "APP_SERVICE_APP_IDENTITY" : "APP_SERVICE_INVALID")
            throw AppServiceContract.refuse(reason)
        }
    }
}
