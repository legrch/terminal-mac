import AppKit
import ServiceManagement
import TerminalMacCore

@MainActor
enum GuestBootstrap {
    /// New installers and native application sessions share this guest-local
    /// lock. Never terminate/replace the installed helper while its service
    /// owns it, or while a predecessor left unresolved private evidence.
    private static func serviceUpdateLease() throws -> AppServiceLock {
        try GuestGuard.requireVirtualMac()
        let root = try AppServiceDirectory.open(GuestAppService.rootURL, createLeaf: true, privateDirectory: true)
        let lease = try root.lock()
        guard !AppServiceFiles.hasUnresolved(in: GuestAppService.rootURL) else {
            throw AppServiceContract.refuse("APP_SERVICE_UNRESOLVED")
        }
        let mailbox = try Mailbox(URL(fileURLWithPath: "/Volumes/My Shared Files/control"))
        guard mailbox.helperUpdateDisposition().mayUpdate else {
            throw AppServiceContract.refuse("APP_SERVICE_CUSTODY")
        }
        return lease
    }
    /// Host-visible, append-only record of helper install/update steps. Best
    /// effort only: a failed log write never changes an install decision.
    nonisolated static let updateLogName = "guest-helper-update.log"
    nonisolated static func log(_ message: String) {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(stamp) pid=\(getpid()) build=\(build) \(message)\n"
        stderr(line.trimmingCharacters(in: .newlines))
        let url = URL(fileURLWithPath: "/Volumes/My Shared Files/control").appendingPathComponent(updateLogName)
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var info = stat()
        if fstat(fd, &info) == 0, info.st_size > 262_144 { _ = ftruncate(fd, 0) }  // bounded log
        _ = line.withCString { write(fd, $0, strlen($0)) }
    }

    static var installedURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications").appendingPathComponent("TerminalMacGuest.app")
    }

    /// Installs `source` at the guest Applications location after validating its
    /// signature against `identity`, then validates the staged copy again.
    /// `except` is never asked to quit (the running helper updating itself).
    struct Installed {
        let destination: URL
        /// Held until the caller finishes its hand-over; released on drop.
        let lease: AppServiceLock
        /// The previous bundle, kept until the successor is confirmed.
        let backup: URL?
        func discardBackup() { if let backup { try? FileManager.default.removeItem(at: backup) } }
        /// Put the previous bundle back after a failed hand-over.
        func restore() {
            guard let backup else { return }
            let failed = destination.deletingLastPathComponent()
                .appendingPathComponent(".TerminalMacGuest-failed-\(UUID().uuidString).app")
            do {
                try FileManager.default.moveItem(at: destination, to: failed)
                try FileManager.default.moveItem(at: backup, to: destination)
                try? FileManager.default.removeItem(at: failed)
            } catch { GuestBootstrap.log("restore failed: \(error.localizedDescription)") }
        }
    }

    static func install(from source: URL, identity: CodeIdentity,
                        exceptPID: pid_t? = nil) async throws -> Installed {
        let destination = installedURL
        let applications = destination.deletingLastPathComponent()
        try identity.validate(source)
        log("install: source validated \(source.path)")
        let updateLease = try serviceUpdateLease()
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
        let installed = Bundle(url: destination)
        let exists = FileManager.default.fileExists(atPath: destination.path)
        if exists, installed?.bundleIdentifier != "dev.terminal-mac.guest" {
            throw Failure("The guest install location is occupied by a different app: \(destination.path)")
        }
        let incoming = Bundle(url: source)
        let keys = ["CFBundleVersion", "CFBundleShortVersionString"]
        let needsUpdate = keys.contains { installed?.object(forInfoDictionaryKey: $0) as? String != incoming?.object(forInfoDictionaryKey: $0) as? String }
        guard !exists || needsUpdate else {
            log("install: already current"); return Installed(destination: destination, lease: updateLease, backup: nil)
        }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "dev.terminal-mac.guest")
            .filter { $0.bundleURL?.resolvingSymlinksInPath() == destination.resolvingSymlinksInPath() &&
                      $0.processIdentifier != exceptPID }
        for application in running { _ = application.terminate() }
        // An installed helper finishing its run loop can take seconds to quit; a
        // short wait refused the install AFTER the old helper had already been
        // asked to quit, leaving no helper running (observed with build 19 -> 20).
        for _ in 0..<400 {
            if running.allSatisfy({ $0.isTerminated }) { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        log("install: \(running.count) other installed helper(s) quit=\(running.allSatisfy { $0.isTerminated })")
        guard running.allSatisfy({ $0.isTerminated }) else {
            log("install: refused, another installed helper did not quit")
            throw Failure("Quit the installed guest helper, then reopen this copy to update it")
        }
        let staging = applications.appendingPathComponent(".TerminalMacGuest-\(UUID().uuidString).app")
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.copyItem(at: source, to: staging)
        try identity.validate(staging)
        let backup = applications.appendingPathComponent(".TerminalMacGuest-backup-\(UUID().uuidString).app")
        if exists { try FileManager.default.moveItem(at: destination, to: backup) }
        do { try FileManager.default.moveItem(at: staging, to: destination) }
        catch {
            if exists { try? FileManager.default.moveItem(at: backup, to: destination) }
            log("install: swap failed \(error.localizedDescription)")
            throw error
        }
        log("install: installed \(destination.path)")
        return Installed(destination: destination, lease: updateLease, backup: exists ? backup : nil)
    }

    /// Launches the installed copy and returns only once it is finished launching
    /// and still alive after a short grace period; otherwise throws (bounded).
    static func launchInstalled(_ destination: URL, timeout: TimeInterval = 30) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        let started = Date()
        var launched: NSRunningApplication?
        var failure: Error?
        NSWorkspace.shared.openApplication(at: destination, configuration: configuration) { app, error in
            Task { @MainActor in launched = app; failure = error }
        }
        while launched == nil && failure == nil {
            guard Date().timeIntervalSince(started) < timeout else { throw Failure("Helper launch timed out") }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        if let failure { throw failure }
        guard let app = launched else { throw Failure("Helper launch returned no application") }
        while !app.isFinishedLaunching {
            guard !app.isTerminated, Date().timeIntervalSince(started) < timeout else {
                throw Failure("Helper did not finish launching")
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try await Task.sleep(nanoseconds: 2_000_000_000)
        guard !app.isTerminated else { throw Failure("Helper exited right after launch") }
        log("launch: running pid=\(app.processIdentifier) \(destination.path)")
    }

    static func installAndRelaunchIfNeeded() async throws -> Bool {
        try GuestGuard.requireVirtualMac()
        guard Bundle.main.bundleIdentifier == "dev.terminal-mac.guest" else { return false }
        let source = Bundle.main.bundleURL.resolvingSymlinksInPath()
        if source == installedURL.resolvingSymlinksInPath() { return false }
        log("explicit install from \(source.path)")
        do {
            let installed = try await install(from: source, identity: try CodeIdentity())
            do { try await launchInstalled(installed.destination) }
            catch { installed.restore(); throw error }
            installed.discardBackup()
            withExtendedLifetime(installed.lease) {}
            return true
        } catch { log("explicit install failed: \(error.localizedDescription)"); throw error }
    }

    /// The installed helper installs a newer copy from the shared tools folder
    /// ITSELF (copy into Applications, validate, swap), launches the installed
    /// copy and then quits. Nothing runs from the shared volume.
    static func updateFromSharedTools(_ tools: URL) {
        guard Bundle.main.bundleIdentifier == "dev.terminal-mac.guest",
              !AppServiceFiles.hasUnresolved(in: GuestAppService.rootURL),
              !updating else { return }
        let shared = tools.appendingPathComponent("TerminalMacGuest.app")
        guard Bundle.main.bundleURL.resolvingSymlinksInPath() != shared.resolvingSymlinksInPath(),
              let available = Bundle(url: shared)?.object(forInfoDictionaryKey: "CFBundleVersion") as? String, let newer = Int(available),
              let running = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""), newer > running else { return }
        updating = true
        log("update: build \(running) -> \(newer) from \(shared.path)")
        Task { @MainActor in
            var installed: Installed?
            do {
                let identity = try CodeIdentity()
                installed = try await install(from: shared, identity: identity, exceptPID: getpid())
                // From here this process admits no new requests: the lease stays
                // held and the successor alone serves the mailbox once confirmed.
                handingOver = true
                try await launchInstalled(installed!.destination)
                installed!.discardBackup()
                log("update: handed over, quitting build \(running)")
                withExtendedLifetime(installed!.lease) { NSApp.terminate(nil) }
            } catch {
                installed?.restore()
                handingOver = false
                updating = false
                log("update: refused or failed: \(error.localizedDescription)")
            }
        }
    }
    private static var updating = false
    /// True while this helper hands over to its successor; the request loop pauses.
    static private(set) var handingOver = false

    static func registerForGuestLogin() {
        guard Bundle.main.bundleIdentifier == "dev.terminal-mac.guest" else { return }
        let preferences = UserDefaults.standard
        guard !preferences.bool(forKey: "requestedGuestLoginItem") else { return }
        do {
            try SMAppService.mainApp.register()
            preferences.set(true, forKey: "requestedGuestLoginItem")
        } catch { stderr("Guest login item: \(error.localizedDescription). You can enable it in the guest's Login Items settings.") }
    }
}
