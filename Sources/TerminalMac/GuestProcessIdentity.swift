import AppKit
import CPhoneShim
import Darwin
import TerminalMacCore

/// Guest-only native metadata access. Never launches ps, scripts, shells or
/// helper processes, and never inspects argv/environment or application data.
@MainActor
enum GuestProcessCensus {
    /// Native reads are injectable so identity races can be tested without
    /// enumerating, observing or launching any operating-system process.
    struct Sampling {
        var requireGuest: () throws -> Void
        var bsd: (Int32) throws -> proc_bsdinfo?
        var path: (Int32) throws -> String
        var pids: () throws -> [Int32]
        var applications: () throws -> [AppGUIObservation]
        var uid: UInt32
    }
    private static var nativeSampling: Sampling {
        Sampling(requireGuest: GuestGuard.requireVirtualMac, bsd: bsd, path: path,
                 pids: pids, applications: applications, uid: geteuid())
    }
    private static func applications() throws -> [AppGUIObservation] {
        let apps = NSWorkspace.shared.runningApplications
        guard apps.count <= AppLaunchIdentity.maximumApplications else {
            throw AppLaunchIdentityError.censusUnavailable
        }
        return apps.map {
            AppGUIObservation(pid: $0.processIdentifier, bundlePath: $0.bundleURL?.path ?? "",
                              bundleID: $0.bundleIdentifier ?? "", executable: $0.executableURL?.path ?? "",
                              regular: $0.activationPolicy == .regular)
        }
    }

    static func timeBoundary() throws -> AppProcessKey {
        var time = timeval()
        guard gettimeofday(&time, nil) == 0, time.tv_sec > 0, time.tv_usec >= 0,
              time.tv_usec < 1_000_000 else { throw AppLaunchIdentityError.censusUnavailable }
        return AppProcessKey(pid: 1, startSeconds: UInt64(time.tv_sec), startMicroseconds: UInt32(time.tv_usec))
    }

    private static func bsd(_ pid: Int32) throws -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        errno = 0
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let count = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        if count <= 0 && errno == ESRCH { return nil }
        guard count == size else { throw AppLaunchIdentityError.censusUnavailable }
        guard info.pbi_pid == UInt32(pid) else { throw AppLaunchIdentityError.changedIdentity }
        guard info.pbi_start_tvsec > 0,
              info.pbi_start_tvusec < 1_000_000, info.pbi_ppid <= UInt32(Int32.max) else {
            throw AppLaunchIdentityError.censusUnavailable
        }
        return info
    }

    private static func path(_ pid: Int32) throws -> String {
        var bytes = [CChar](repeating: 0, count: 4096)
        let count = proc_pidpath(pid, &bytes, UInt32(bytes.count))
        guard count > 0, Int(count) < bytes.count, let zero = bytes.firstIndex(of: 0), zero > 0 else {
            throw AppLaunchIdentityError.censusUnavailable
        }
        let raw = bytes.prefix(zero).map { UInt8(bitPattern: $0) }
        guard let path = String(bytes: raw, encoding: .utf8), path.hasPrefix("/") else {
            throw AppLaunchIdentityError.censusUnavailable
        }
        return path
    }

    /// `observeKey` sees every successful BSD read's immutable key (PID, start,
    /// UID) before any further fallible read, so a forbidden identity that then
    /// vanishes is still reported instead of becoming absence.
    static func process(_ pid: Int32, sampling injected: Sampling? = nil,
                        observeKey: (AppProcessKey, UInt32) throws -> Void = { _, _ in }) throws -> AppProcessSnapshot? {
        let sampling = injected ?? nativeSampling
        try sampling.requireGuest()
        guard pid > 0 else { throw AppLaunchIdentityError.censusUnavailable }
        func key(_ info: proc_bsdinfo) -> AppProcessKey {
            AppProcessKey(pid: pid, startSeconds: info.pbi_start_tvsec,
                          startMicroseconds: UInt32(truncatingIfNeeded: info.pbi_start_tvusec))
        }
        guard let before = try sampling.bsd(pid) else { return nil }
        try observeKey(key(before), before.pbi_uid)
        // Parent PID is ancestry, not identity: reparenting is permitted.
        func requireSameIdentity(_ after: proc_bsdinfo) throws {
            guard before.pbi_pid == UInt32(pid), after.pbi_pid == UInt32(pid),
                  before.pbi_start_tvsec == after.pbi_start_tvsec,
                  before.pbi_start_tvusec == after.pbi_start_tvusec,
                  before.pbi_uid == after.pbi_uid else { throw AppLaunchIdentityError.changedIdentity }
        }
        // Absence is not an identity transition, but it must never erase an
        // immutable identity mismatch already observed in successful reads.
        func pathOrAbsent() throws -> String? {
            do { return try sampling.path(pid) } catch {
                guard let current = try sampling.bsd(pid) else { return nil }
                try observeKey(key(current), current.pbi_uid)
                try requireSameIdentity(current)
                throw error
            }
        }
        guard let executable = try pathOrAbsent() else { return nil }
        guard let after = try sampling.bsd(pid) else { return nil }
        try observeKey(key(after), after.pbi_uid)
        try requireSameIdentity(after)
        guard let again = try pathOrAbsent() else { return nil }
        guard executable == again else { throw AppLaunchIdentityError.changedIdentity }
        return AppProcessSnapshot(
            key: AppProcessKey(pid: pid, startSeconds: after.pbi_start_tvsec,
                               startMicroseconds: UInt32(after.pbi_start_tvusec)),
            parentPID: Int32(after.pbi_ppid), uid: after.pbi_uid, executable: executable)
    }

    private static func pids() throws -> [Int32] {
        var ids = [Int32](repeating: 0, count: AppLaunchIdentity.maximumProcesses + 1)
        let bytes = ids.count * MemoryLayout<Int32>.size
        let result = proc_listpids(UInt32(PROC_UID_ONLY), geteuid(), &ids, Int32(bytes))
        guard result >= 0, Int(result) < bytes, result % Int32(MemoryLayout<Int32>.size) == 0 else {
            throw AppLaunchIdentityError.censusUnavailable
        }
        let selected = ids.prefix(Int(result) / MemoryLayout<Int32>.size).filter { $0 > 0 }.sorted()
        guard !selected.isEmpty, selected.count <= AppLaunchIdentity.maximumProcesses,
              Set(selected).count == selected.count else { throw AppLaunchIdentityError.censusUnavailable }
        return selected
    }

    static func capture() throws -> AppProcessCensus {
        // Process creation during cold startup invalidates one READ snapshot,
        // not the already-bound launch. Re-read a bounded complete census;
        // never omit an unreadable process or repeat an application effect.
        try AppLaunchIdentity.stableCensus { try captureOnce() }
    }

    /// Quit/close need the whole application registry, including entries whose
    /// original processes have already exited. The launch census deliberately
    /// joins live PIDs; reusing that join here would hide delayed registry
    /// removal and could falsely attest a completely drained application.
    ///
    /// This is one complete read attempt. PID-list churn may be resampled by
    /// the caller; forbidden identity observations fail permanently. Unreadable
    /// processes are never omitted or called positive survivors. The original
    /// deadline/cancellation/custody check runs throughout enumeration.
    /// `observe` / `observeApplications` validate each qualified observation
    /// BEFORE a torn census may be discarded, so evidence of a changed or new
    /// accepted identity in a sample that is later torn still fails at once.
    /// The bounded torn-read sampler around one complete census. Each attempt
    /// re-runs the caller's checks and the per-observation identity hooks, so an
    /// observed violation fails at once instead of being resampled away.
    static func stableCaptureForQuit(check: () throws -> Void,
                                     observe: (AppProcessSnapshot) throws -> Void = { _ in },
                                     observeApplications: ([AppGUIObservation]) throws -> Void = { _ in },
                                     observeKey: (AppProcessKey, UInt32) throws -> Void = { _, _ in },
                                     sampling injected: Sampling? = nil) throws -> AppProcessCensus {
        try AppLaunchIdentity.stableCensus {
            try captureForQuit(check: check, observe: observe,
                               observeApplications: observeApplications,
                               observeKey: observeKey, sampling: injected)
        }
    }

    static func captureForQuit(check: () throws -> Void,
                               observe: (AppProcessSnapshot) throws -> Void = { _ in },
                               observeApplications: ([AppGUIObservation]) throws -> Void = { _ in },
                               observeKey: (AppProcessKey, UInt32) throws -> Void = { _, _ in },
                               sampling injected: Sampling? = nil) throws -> AppProcessCensus {
        let sampling = injected ?? nativeSampling
        try sampling.requireGuest()
        try Task.checkCancellation()
        try check()
        let before = try sampling.pids()
        var processes: [AppProcessSnapshot] = []
        for pid in before {
            try Task.checkCancellation()
            try check()
            guard let process = try GuestProcessCensus.process(pid, sampling: sampling, observeKey: observeKey) else {
                throw AppLaunchIdentityError.censusChanged
            }
            try observe(process)
            guard process.uid == sampling.uid else { throw AppLaunchIdentityError.changedIdentity }
            processes.append(process)
        }
        // Do not filter by PID membership, isTerminated or activationPolicy:
        // each accepted-tree registry entry must disappear observably. Unknown
        // registry metadata is handled fail-closed by the frozen Core policy.
        let applications = try sampling.applications()
        try observeApplications(applications)
        guard before == (try sampling.pids()) else { throw AppLaunchIdentityError.censusChanged }
        try Task.checkCancellation()
        try check()
        return AppProcessCensus(processes: processes, applications: applications, complete: true)
    }

    private static func captureOnce() throws -> AppProcessCensus {
        try GuestGuard.requireVirtualMac()
        let before = try pids()
        var processes: [AppProcessSnapshot] = []
        for pid in before {
            guard let process = try GuestProcessCensus.process(pid) else {
                throw AppLaunchIdentityError.censusChanged
            }
            guard process.uid == geteuid() else { throw AppLaunchIdentityError.changedIdentity }
            processes.append(process)
        }
        // Do not silently omit an unreadable or newly appearing current-user
        // process. A changed census can be observed again, never called empty.
        guard before == (try pids()) else { throw AppLaunchIdentityError.censusChanged }
        let ids = Set(before)
        let apps = NSWorkspace.shared.runningApplications.filter { !$0.isTerminated && ids.contains($0.processIdentifier) }
        guard apps.count <= AppLaunchIdentity.maximumApplications else { throw AppLaunchIdentityError.censusUnavailable }
        let applications = apps.map {
            AppGUIObservation(pid: $0.processIdentifier, bundlePath: $0.bundleURL?.path ?? "",
                              bundleID: $0.bundleIdentifier ?? "", executable: $0.executableURL?.path ?? "",
                              regular: $0.activationPolicy == .regular)
        }
        return AppProcessCensus(processes: processes, applications: applications, complete: true)
    }
}

/// A NOTE_EXIT observer is registered while the exact PID/start/executable is
/// still alive and rechecked afterwards. Closing the descriptor does NOT kill
/// or reap the application. No watcher is reconstructed after helper restart.
@MainActor
final class GuestOriginalProcessObserver {
    let expected: AppProcessSnapshot
    private let queue: Int32
    private let sample: () throws -> AppProcessSnapshot?
    private let originalExit: () throws -> Bool
    private var exited = false
    private var invalid = false

    init(_ process: AppProcessSnapshot) throws {
        try GuestGuard.requireVirtualMac()
        guard let before = try GuestProcessCensus.process(process.key.pid), before.sameProcess(as: process) else {
            throw AppLaunchIdentityError.changedIdentity
        }
        let acquired = kqueue()
        guard acquired >= 0 else { throw AppLaunchIdentityError.observationUnavailable }
        var transferred = false
        defer { if !transferred { close(acquired) } }
        guard fcntl(acquired, F_SETFD, FD_CLOEXEC) == 0 else {
            throw AppLaunchIdentityError.observationUnavailable
        }
        var change = kevent(ident: UInt(process.key.pid), filter: Int16(EVFILT_PROC),
                            flags: UInt16(EV_ADD | EV_ONESHOT | EV_RECEIPT),
                            fflags: UInt32(NOTE_EXIT), data: 0, udata: nil)
        var receipt = kevent()
        let count = tp_kevent(acquired, &change, 1, &receipt, 1, nil)
        guard count == 1, receipt.ident == UInt(process.key.pid), receipt.filter == Int16(EVFILT_PROC),
              receipt.flags & UInt16(EV_ERROR) != 0, receipt.data == 0 else {
            throw AppLaunchIdentityError.observationUnavailable
        }
        guard let after = try GuestProcessCensus.process(process.key.pid), after.sameProcess(as: process) else {
            throw AppLaunchIdentityError.changedIdentity
        }
        // Transfer only on successful initialization; no double-close on a
        // throwing initializer or risk of closing a newly reused descriptor.
        expected = process; queue = acquired
        // Every raw BSD read is checked against the original key first, so a
        // replacement that vanishes before path qualification still poisons.
        sample = {
            try GuestProcessCensus.process(process.key.pid, observeKey: { key, uid in
                guard key == process.key, uid == process.uid else { throw AppLaunchIdentityError.changedIdentity }
            })
        }
        originalExit = { try Self.pollExit(queue: acquired, pid: process.key.pid) }
        transferred = true
    }
    /// Test seam for the same life() path, without allocating a kernel observer.
    init(_ process: AppProcessSnapshot, sample: @escaping () throws -> AppProcessSnapshot?,
         originalExit: @escaping () throws -> Bool) {
        expected = process; queue = -1; self.sample = sample; self.originalExit = originalExit
    }
    deinit { if queue >= 0 { close(queue) } }

    private static func pollExit(queue: Int32, pid: Int32) throws -> Bool {
        var event = kevent()
        var timeout = timespec(tv_sec: 0, tv_nsec: 0)
        let count = tp_kevent(queue, nil, 0, &event, 1, &timeout)
        if count == 1 {
            guard event.ident == UInt(pid), event.filter == Int16(EVFILT_PROC),
                  event.flags & UInt16(EV_ERROR) == 0, event.fflags & UInt32(NOTE_EXIT) != 0 else {
                throw AppLaunchIdentityError.observationUnavailable
            }
            return true
        }
        guard count == 0 else { throw AppLaunchIdentityError.observationUnavailable }
        return false
    }

    func life() -> AppProcessLife {
        if invalid { return .unknown }
        if exited { return .exited }
        do {
            if try originalExit() {
                exited = true
                return AppLaunchIdentity.life(of: expected, observation: .originalExit(expected.key))
            }
        } catch { invalid = true; return .unknown }
        do {
            let actual = try sample()
            let life = AppLaunchIdentity.life(of: expected,
                observation: actual.map(AppProcessObservation.live) ?? .absent)
            // A changed live identity poisons this ownership. A missing sample
            // is exitPending: the original kernel event may still arrive and be
            // observed without repeating any process operation.
            if let actual, !actual.sameProcess(as: expected) { invalid = true }
            return life
        } catch let error as AppLaunchIdentityError where error == .censusChanged || error == .changedIdentity {
            // A live identity transition was observed: poison, never wait it out.
            invalid = true; return .unknown
        } catch { return .exitPending }
    }
}

/// One original launch attempt, including its returned-but-unadmitted metadata.
/// Only a successfully bound regular GUI primary is ever activated or asked to
/// Quit. The launch root and other accepted descendants are never signalled.
@MainActor
final class GuestApplicationLifecycle {
    let plan: AppLaunchPlan
    let before: AppProcessCensus
    let notBefore: AppProcessKey
    private(set) var returned: NSRunningApplication?
    private(set) var returnedProcess: AppProcessSnapshot?
    private(set) var binding: AppLaunchBinding?
    private(set) var primaryApplication: NSRunningApplication?
    private var rootObserver: GuestOriginalProcessObserver?
    private var primaryObserver: GuestOriginalProcessObserver?
    private(set) var failure: AppLaunchIdentityError?
    private var quitIssued = false
    private var quitDrain: AppQuitDrain?
    private var quitProgress: AppQuitDrainProgress?
    private var quitInventoryReadAttempts = 0
    /// Last quit step entered; a diagnostic label only, never authority.
    private var quitStep = "not-started"

    init(plan: AppLaunchPlan, before: AppProcessCensus, notBefore: AppProcessKey) {
        self.plan = plan; self.before = before; self.notBefore = notBefore
    }

    func receive(_ app: NSRunningApplication) {
        returned = app
        do {
            returnedProcess = try GuestProcessCensus.process(app.processIdentifier)
            if returnedProcess == nil { failure = .returnedChanged }
        } catch { failure = (error as? AppLaunchIdentityError) ?? .censusUnavailable }
    }

    func qualify(check: () throws -> Void) async throws {
        guard let returnedProcess else { throw failure ?? AppLaunchIdentityError.returnedChanged }
        let until = ContinuousClock.now.advanced(by: .seconds(8))
        while true {
            try check()
            do {
                let census = try GuestProcessCensus.capture()
                let selected = try AppLaunchIdentity.bind(plan: plan, before: before, after: census,
                    returned: returnedProcess.key, notBefore: notBefore, uid: geteuid())
                let root = try GuestOriginalProcessObserver(selected.root)
                let primary: GuestOriginalProcessObserver
                if selected.primary.key == selected.root.key { primary = root }
                else { primary = try GuestOriginalProcessObserver(selected.primary) }
                let repeated = try GuestProcessCensus.capture()
                let confirmed = try AppLaunchIdentity.bind(plan: plan, before: before, after: repeated,
                    returned: returnedProcess.key, notBefore: notBefore, uid: geteuid())
                try AppLaunchIdentity.requireSameBinding(selected, confirmed)
                guard let app = NSRunningApplication(processIdentifier: selected.primary.key.pid),
                      !app.isTerminated, app.activationPolicy == .regular,
                      plan.guiBundle(path: app.bundleURL?.path ?? "", identifier: app.bundleIdentifier ?? "",
                                     executable: app.executableURL?.path ?? "") == selected.primaryBundle else {
                    throw AppLaunchIdentityError.metadataMismatch
                }
                try check()
                binding = confirmed; rootObserver = root; primaryObserver = primary
                primaryApplication = app; failure = nil
                return
            } catch let error as AppLaunchIdentityError {
                // These are bounded new READ observations while the original
                // launch settles, never another LaunchServices request.
                guard (error == .noPrimary || error == .censusChanged), ContinuousClock.now < until else {
                    failure = error; throw error
                }
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    func requireLive() throws -> NSRunningApplication {
        guard failure == nil, let binding, let returnedProcess,
              rootObserver?.life() == .running, primaryObserver?.life() == .running,
              let app = primaryApplication, !app.isTerminated else {
            throw AppLaunchIdentityError.changedIdentity
        }
        do {
            let now = try AppLaunchIdentity.bind(plan: plan, before: before,
                after: GuestProcessCensus.capture(), returned: returnedProcess.key,
                notBefore: notBefore, uid: geteuid())
            try AppLaunchIdentity.requireSameBinding(binding, now)
            guard app.processIdentifier == binding.primary.key.pid,
                  app.activationPolicy == .regular,
                  plan.guiBundle(path: app.bundleURL?.path ?? "", identifier: app.bundleIdentifier ?? "",
                                 executable: app.executableURL?.path ?? "") == binding.primaryBundle else {
                throw AppLaunchIdentityError.metadataMismatch
            }
            return app
        } catch {
            failure = (error as? AppLaunchIdentityError) ?? .censusUnavailable
            throw error
        }
    }

    func quit(check: () throws -> Void) async throws {
        guard !quitIssued, let binding, let returnedProcess, failure == nil else {
            throw AppLaunchIdentityError.exitUnconfirmed
        }
        quitStep = "pre-effect-admission"
        try Task.checkCancellation()
        try check()
        let primaryLife = primaryObserver?.life() ?? .unknown
        let rootLife = rootObserver?.life() ?? .unknown
        try AppLaunchIdentity.requireNormalQuitAdmission(root: rootLife, primary: primaryLife)
        let app = try requireLive()

        // Freeze the currently proved descendants/registry BEFORE terminate.
        // Rebinding is only a comparison with the original root/primary; it
        // creates no observer, process authority or new lifecycle. Accepted
        // processes first seen after this boundary cannot be adopted as ours.
        // No termination has been requested yet. Establish one complete
        // pre-effect snapshot with the same bounded torn-read sampling used
        // at launch. Every sample retains the original request checks; no
        // partial census is accepted and no application effect is repeated.
        // Post-terminate drain/close observations remain strict single reads.
        quitStep = "pre-effect-census"
        let beforeQuit = try AppLaunchIdentity.stableCensus {
            try GuestProcessCensus.captureForQuit(check: check)
        }
        quitStep = "pre-effect-binding"
        let confirmed = try AppLaunchIdentity.bind(plan: plan, before: before,
            after: beforeQuit, returned: returnedProcess.key, notBefore: notBefore, uid: geteuid())
        try AppLaunchIdentity.requireSameBinding(binding, confirmed)
        let drain = try AppQuitDrain(plan: plan, binding: confirmed, beforeQuit: beforeQuit)
        quitDrain = drain
        quitProgress = nil
        quitInventoryReadAttempts = 0
        quitStep = "terminate-admission"

        try await drain.run(check: check, terminatePrimary: {
            guard !self.quitIssued, !app.isTerminated,
                  app.processIdentifier == binding.primary.key.pid,
                  self.primaryApplication === app else {
                throw AppLaunchIdentityError.changedIdentity
            }
            self.quitIssued = true  // Even a false return is never retried.
            self.quitStep = "drain-originals"
            return app.terminate()   // The only normal termination request.
        }, originals: {
            (root: self.rootObserver?.life() ?? .unknown,
             primary: self.primaryObserver?.life() ?? .unknown)
        }, inventory: {
            self.quitInventoryReadAttempts += 1
            self.quitStep = "drain-inventory"
            return try GuestProcessCensus.captureForQuit(check: check,
                observe: { try drain.requireAdmissible($0) },
                observeApplications: { try drain.requireAdmissible(applications: $0) },
                observeKey: { try drain.requireAdmissible(key: $0, uid: $1) })
        }, nextObservation: {
            // Scheduling cadence ONLY. Each new sample rechecks the original
            // request deadline/cancellation; elapsed time never proves exit.
            try await Task.sleep(nanoseconds: 50_000_000)
        }, observed: { progress in
            self.quitProgress = progress
        })
        quitStep = "quiescent"
        try check()
    }

    func requireExited(check: () throws -> Void) throws {
        // Close does its own fresh kernel/census check, not a cached successful
        // Quit or another round of cleanup. An earlier UNKNOWN is never healed.
        guard failure == nil, quitIssued, let binding, let drain = quitDrain else {
            throw AppLaunchIdentityError.exitUnconfirmed
        }
        try Task.checkCancellation()
        try check()
        guard primaryApplication?.processIdentifier == binding.primary.key.pid else {
            throw AppLaunchIdentityError.changedIdentity
        }
        guard try AppQuitDrain.originalsExited(root: rootObserver?.life() ?? .unknown,
                                              primary: primaryObserver?.life() ?? .unknown) else {
            throw AppLaunchIdentityError.exitUnconfirmed
        }
        quitInventoryReadAttempts += 1
        // Same bounded torn-read sampler and identity hooks as the drain: a
        // census torn by unrelated churn is re-read; an observed change fails.
        let census = try GuestProcessCensus.stableCaptureForQuit(check: check,
            observe: { try drain.requireAdmissible($0) },
            observeApplications: { try drain.requireAdmissible(applications: $0) },
                observeKey: { try drain.requireAdmissible(key: $0, uid: $1) })
        try drain.requireQuiescent(root: rootObserver?.life() ?? .unknown,
                                   primary: primaryObserver?.life() ?? .unknown, census: census)
        try Task.checkCancellation()
        try check()
        quitProgress = .quiescent
        // No claim about arbitrary detached descendants on unrelated paths.
        // GuestAppService.close still separately verifies the installed tree.
    }

    func note(_ error: Error) {
        failure = (error as? AppLaunchIdentityError) ?? failure ?? .observationUnavailable
    }

    func diagnosticValues() -> [String: String] {
        var values: [String: String] = [
            "launchIdentityContract": AppLaunchIdentity.contract,
            "launchIdentityState": binding == nil ? "unconfirmed" : (failure == nil ? "bound" : "unknown"),
            "launchIdentityReason": failure?.rawValue ?? "NONE",
            "returnedPID": returned.map { String($0.processIdentifier) } ?? "",
            "returnedExecutable": plan.diagnosticPath(returned?.executableURL?.path),
            "returnedBundle": plan.diagnosticPath(returned?.bundleURL?.path),
            "returnedKernelExecutable": plan.diagnosticPath(returnedProcess?.executable),
            "returnedStartIdentity": returnedProcess?.key.token ?? "unconfirmed",
            "rootExit": "unconfirmed", "uiPrimaryExit": "unconfirmed",
            "applicationRunning": "unconfirmed", "descendantCleanup": "unverified",
            "normalQuitRequested": String(quitIssued)
        ]
        values["quitInventoryReadAttempts"] = String(quitInventoryReadAttempts)
        values["quitStep"] = quitStep
        switch quitProgress {
        case .some(.originalExitsPending(_, _)):
            values["quitDrainState"] = "original-exits-pending"
        case .some(.inventoryPending(let processes, let applications)):
            values["quitDrainState"] = "accepted-inventory-pending"
            values["quitResidualProcesses"] = String(processes)
            values["quitResidualApplications"] = String(applications)
        case .some(.inventoryUnobserved(let tornSamples)):
            values["quitDrainState"] = "accepted-inventory-unobserved"
            values["quitTornSamples"] = String(tornSamples)
        case .some(.quiescent):
            values["quitDrainState"] = "observed-quiescent"
            values["quitResidualProcesses"] = "0"
            values["quitResidualApplications"] = "0"
        case .none:
            values["quitDrainState"] = "not-observed"
        }
        if failure != nil, quitIssued {
            // A later expired request or failed close cannot reuse a previous
            // empty sample as current completion evidence.
            values["quitLastObservation"] = values["quitDrainState"]
            values["quitDrainState"] = "unconfirmed"
        }
        if let identifier = returned?.bundleIdentifier, !identifier.isEmpty, identifier.utf8.count <= 160,
           identifier.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) ||
               (97...122).contains($0) || [45, 46].contains($0) }) {
            values["returnedBundleIdentifier"] = identifier
        } else { values["returnedBundleIdentifier"] = "unavailable" }
        if let binding {
            values["launchRootPID"] = String(binding.root.key.pid)
            values["launchRootStartIdentity"] = binding.root.key.token
            values["launchRootExecutable"] = plan.diagnosticPath(binding.root.executable)
            values["uiPrimaryPID"] = String(binding.primary.key.pid)
            values["uiPrimaryStartIdentity"] = binding.primary.key.token
            values["uiPrimaryExecutable"] = plan.diagnosticPath(binding.primary.executable)
            values["uiPrimaryBundleIdentifier"] = binding.primaryBundle.identifier
            values["launchRootEqualsPrimary"] = String(binding.root.key == binding.primary.key)
            values["launchAncestry"] = binding.ancestry.map { $0.key.token }.joined(separator: ">")
            values["uiPrimaryParentPID"] = String(binding.primary.parentPID)
            values["launchRootParentPID"] = String(binding.root.parentPID)
            values["acceptedDescendantsAtBinding"] = String(binding.descendants.count)
            values["acceptedDescendantIdentities"] = binding.descendants.prefix(32).map { $0.key.token }.joined(separator: ",")
            values["descendantIdentitiesTruncated"] = String(binding.descendants.count > 32)
            let root = rootObserver?.life() ?? .unknown
            let primary = primaryObserver?.life() ?? .unknown
            values["rootExit"] = root == .exited ? "observed" : root == .running ? "not-observed" : "unconfirmed"
            values["uiPrimaryExit"] = primary == .exited ? "observed" : primary == .running ? "not-observed" : "unconfirmed"
            values["applicationRunning"] = primary == .exited ? "false" : primary == .running ? "true" : "unconfirmed"
            if root == .unknown || primary == .unknown { values["launchIdentityState"] = "unknown" }
        }
        return values
    }
}
