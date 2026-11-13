import Foundation

/// Positive observations are deliberately different from an unavailable or
/// changed identity. Waiting never grants ownership of another process.
public enum AppQuitDrainProgress: Equatable {
    case originalExitsPending(root: AppProcessLife, primary: AppProcessLife)
    case inventoryPending(processes: Int, applications: Int)
    /// After both original exits, the bounded torn-read sampler still saw the
    /// process list change on every sample. This is NOT a survivor count and
    /// NOT quiescence: nothing was observed, so the drain keeps waiting under
    /// the caller's original deadline and never completes on this sample.
    case inventoryUnobserved(tornSamples: Int)
    case quiescent
}

/// A frozen, identity-qualified pre-Quit inventory. It has no process APIs,
/// clocks, filesystem access or mutations. Native code constructs it only
/// after revalidating the original launch binding against a complete census.
///
/// After both original NOTE_EXIT observations, an unchanged accepted process
/// or an unchanged LaunchServices entry is positive evidence to keep waiting.
/// Missing/unreadable data, a reused PID, changed metadata or a new accepted
/// process is NOT this state and must fail immediately, without re-adoption.
public struct AppQuitDrain {
    private let plan: AppLaunchPlan
    private let known: [Int32: AppProcessSnapshot]
    private let registered: [Int32: AppGUIObservation]

    public init(plan: AppLaunchPlan, binding: AppLaunchBinding,
                beforeQuit: AppProcessCensus) throws {
        let processes = try Self.index(beforeQuit)
        guard binding.root.key.valid, binding.primary.key.valid,
              plan.acceptsExecutable(binding.root.executable),
              plan.acceptsExecutable(binding.primary.executable),
              binding.root.uid == binding.primary.uid,
              binding.ancestry.first?.sameProcess(as: binding.primary) == true,
              binding.ancestry.last?.sameProcess(as: binding.root) == true,
              binding.ancestry.count <= AppLaunchIdentity.maximumAncestry,
              binding.descendants.count <= AppLaunchIdentity.maximumBundleProcesses else {
            throw AppLaunchIdentityError.changedIdentity
        }
        var accepted: [Int32: AppProcessSnapshot] = [:]
        for process in [binding.root, binding.primary] + binding.ancestry + binding.descendants {
            guard process.key.valid, plan.acceptsExecutable(process.executable),
                  process.uid == binding.root.uid,
                  let current = processes[process.key.pid], current.sameProcess(as: process) else {
                throw AppLaunchIdentityError.changedIdentity
            }
            if let prior = accepted[process.key.pid], !prior.sameProcess(as: process) {
                throw AppLaunchIdentityError.changedIdentity
            }
            accepted[process.key.pid] = process
        }
        guard accepted.count <= AppLaunchIdentity.maximumBundleProcesses else {
            throw AppLaunchIdentityError.censusUnavailable
        }
        // Binding must cover every accepted-tree process in this very census.
        // It is not enough to have observed the same root/primary earlier.
        for process in processes.values where plan.contains(process.executable) {
            guard let expected = accepted[process.key.pid], expected.sameProcess(as: process) else {
                throw AppLaunchIdentityError.unrelatedRoot
            }
        }
        var apps: [Int32: AppGUIObservation] = [:]
        for app in beforeQuit.applications {
            let relevant = accepted[app.pid] != nil || plan.contains(app.executable) ||
                plan.containsBundle(app.bundlePath)
            guard relevant else { continue }
            guard let process = accepted[app.pid],
                  plan.containsBundle(app.bundlePath), !app.bundleID.isEmpty,
                  app.executable.isEmpty || app.executable == process.executable ||
                    plan.isOuterLauncherMetadata(app, process: process) else {
                throw AppLaunchIdentityError.metadataMismatch
            }
            // Background vendor registry entries can lack an executable URL.
            // The already-proved native process supplies that identity BEFORE
            // Quit; freezing its registry metadata does not make it a GUI owner.
            apps[app.pid] = app
        }
        self.plan = plan
        known = accepted; registered = apps
    }

    private static func index(_ census: AppProcessCensus) throws -> [Int32: AppProcessSnapshot] {
        guard census.complete,
              census.processes.count <= AppLaunchIdentity.maximumProcesses,
              census.applications.count <= AppLaunchIdentity.maximumApplications else {
            throw AppLaunchIdentityError.censusUnavailable
        }
        var processes: [Int32: AppProcessSnapshot] = [:]
        for process in census.processes {
            guard process.key.valid, process.parentPID >= 0,
                  process.executable.hasPrefix("/"), process.executable.utf8.count <= 4096,
                  !process.executable.contains("\0"), processes[process.key.pid] == nil else {
                throw AppLaunchIdentityError.censusUnavailable
            }
            processes[process.key.pid] = process
        }
        var seen: Set<Int32> = []
        for app in census.applications {
            guard app.pid > 0, seen.insert(app.pid).inserted,
                  app.bundlePath.utf8.count <= 4096, app.executable.utf8.count <= 4096,
                  app.bundleID.utf8.count <= 160,
                  !app.bundlePath.contains("\0"), !app.executable.contains("\0"),
                  !app.bundleID.contains("\0") else {
                throw AppLaunchIdentityError.censusUnavailable
            }
        }
        return processes
    }

    public static func originalsExited(root: AppProcessLife, primary: AppProcessLife) throws -> Bool {
        guard root != .unknown, primary != .unknown else {
            throw AppLaunchIdentityError.observationUnavailable
        }
        // `exitPending` is "not yet": absence before the original NOTE_EXIT is
        // dequeued never completes a drain and never fails it by itself.
        return root == .exited && primary == .exited
    }

    public func progress(root: AppProcessLife, primary: AppProcessLife,
                         census: AppProcessCensus? = nil) throws -> AppQuitDrainProgress {
        guard try Self.originalsExited(root: root, primary: primary) else {
            return .originalExitsPending(root: root, primary: primary)
        }
        guard let census else { throw AppLaunchIdentityError.censusUnavailable }
        let processes = try Self.index(census)
        // NOTE_EXIT is positive evidence about the ORIGINAL process. Do not
        // mistake a reused numeric PID or an exec/UID change for that identity,
        // even when the replacement executable is outside the accepted tree.
        for (pid, expected) in known {
            if let current = processes[pid], !current.sameProcess(as: expected) {
                throw AppLaunchIdentityError.changedIdentity
            }
        }
        var survivors = 0
        for process in processes.values where plan.contains(process.executable) {
            guard let expected = known[process.key.pid], expected.sameProcess(as: process) else {
                throw AppLaunchIdentityError.unrelatedRoot
            }
            survivors += 1
        }
        var applications = 0
        for app in census.applications {
            let relevant = known[app.pid] != nil || plan.contains(app.executable) ||
                plan.containsBundle(app.bundlePath)
            guard relevant else { continue }
            guard let expected = registered[app.pid],
                  app.bundlePath == expected.bundlePath, app.bundleID == expected.bundleID,
                  app.executable == expected.executable else {
                throw AppLaunchIdentityError.metadataMismatch
            }
            // Do not filter registry survivors by the process PID list: delayed
            // LaunchServices removal is precisely one of the states to drain.
            // Activation policy can change during Quit; it confers no authority
            // here and cannot cause an entry to be silently dropped.
            applications += 1
        }
        return survivors == 0 && applications == 0 ? .quiescent :
            .inventoryPending(processes: survivors, applications: applications)
    }

    /// Per-observation checks for a census still being read. A changed known
    /// identity or an unknown accepted process fails even if that sample is
    /// later torn and discarded; unrelated processes and exits are admissible.
    public func requireAdmissible(_ process: AppProcessSnapshot) throws {
        if let expected = known[process.key.pid], !expected.sameProcess(as: process) {
            throw AppLaunchIdentityError.changedIdentity
        }
        if plan.contains(process.executable) {
            guard let expected = known[process.key.pid], expected.sameProcess(as: process) else {
                throw AppLaunchIdentityError.unrelatedRoot
            }
        }
    }

    /// Raw kernel key check, applied to every successful BSD read before any
    /// further fallible read: a known PID with another start or UID is a change.
    public func requireAdmissible(key: AppProcessKey, uid: UInt32) throws {
        if let expected = known[key.pid], expected.key != key || expected.uid != uid {
            throw AppLaunchIdentityError.changedIdentity
        }
    }

    public func requireAdmissible(applications: [AppGUIObservation]) throws {
        for app in applications {
            let relevant = known[app.pid] != nil || plan.contains(app.executable) ||
                plan.containsBundle(app.bundlePath)
            guard relevant else { continue }
            guard let expected = registered[app.pid],
                  app.bundlePath == expected.bundlePath, app.bundleID == expected.bundleID,
                  app.executable == expected.executable else {
                throw AppLaunchIdentityError.metadataMismatch
            }
        }
    }

    /// Close uses a NEW complete observation, not the previous Quit result.
    /// It never waits, signals or repairs a failed/unknown operation.
    public func requireQuiescent(root: AppProcessLife, primary: AppProcessLife,
                                 census: AppProcessCensus) throws {
        guard try progress(root: root, primary: primary, census: census) == .quiescent else {
            throw AppLaunchIdentityError.exitUnconfirmed
        }
    }

    /// Shared production/test orchestration. The only effect closure is called
    /// once, before any waiting. The caller's ORIGINAL deadline/custody check
    /// bounds every observation and scheduling yield; this function creates no
    /// timeout, renewable budget, retry lease or wall-clock completion rule.
    ///
    /// A census exception is never caught as a retryable survivor. Yield only
    /// controls sample cadence; no number of yields establishes completion.
    ///
    /// After the original exits, the accepted tree is tearing down and its PIDs
    /// churn. A torn read (`censusChanged`) is re-read with the same bounded
    /// sampler used before Quit (`AppLaunchIdentity.stableCensus`); if every
    /// sample is still torn, that observation is `.inventoryUnobserved` and the
    /// loop waits for the next one. It is never counted as a survivor or as an
    /// empty inventory. Every other census error, a changed original identity,
    /// a new or reused accepted PID, and the original deadline still fail at once.
    @MainActor
    public func run(check: () throws -> Void,
                    terminatePrimary: () throws -> Bool,
                    originals: () -> (root: AppProcessLife, primary: AppProcessLife),
                    inventory: () throws -> AppProcessCensus,
                    nextObservation: () async throws -> Void,
                    observed: (AppQuitDrainProgress) -> Void = { _ in }) async throws {
        var tornSamples = 0
        try Task.checkCancellation()
        try check()
        let initial = originals()
        try AppLaunchIdentity.requireNormalQuitAdmission(root: initial.root, primary: initial.primary)
        try Task.checkCancellation()
        try check()
        // Custody/deadline checking can itself take time. Do not call normal
        // Quit on a primary whose original root exited during that check.
        let dispatch = originals()
        try AppLaunchIdentity.requireNormalQuitAdmission(root: dispatch.root, primary: dispatch.primary)
        guard try terminatePrimary() else { throw AppLaunchIdentityError.exitUnconfirmed }
        while true {
            try Task.checkCancellation()
            try check()
            let state = originals()
            let exited = try Self.originalsExited(root: state.root, primary: state.primary)
            let census: AppProcessCensus?
            if exited {
                try check()
                do {
                    census = try AppLaunchIdentity.stableCensus {
                        try check()
                        return try inventory()
                    }
                } catch AppLaunchIdentityError.censusChanged {
                    // Unobserved, not a survivor: no state is inferred from it.
                    tornSamples += 1
                    observed(.inventoryUnobserved(tornSamples: tornSamples))
                    try Task.checkCancellation()
                    try check()
                    try await nextObservation()
                    continue
                }
                // Native metadata reads consume real time too. Expiry or
                // cancellation during a complete empty sample is not success.
                try Task.checkCancellation()
                try check()
                let afterRead = originals()
                guard try Self.originalsExited(root: afterRead.root, primary: afterRead.primary) else {
                    throw AppLaunchIdentityError.exitUnconfirmed
                }
            } else {
                census = nil
            }
            let result = try progress(root: state.root, primary: state.primary, census: census)
            observed(result)
            if result == .quiescent {
                try Task.checkCancellation()
                try check()
                return
            }
            try Task.checkCancellation()
            try check()
            try await nextObservation()
        }
    }
}
