import Foundation

/// Content-free native process observations. These values do not execute,
/// enumerate, adopt, signal or authorize a process by themselves.
public struct AppProcessKey: Codable, Equatable, Hashable {
    public let pid: Int32
    public let startSeconds: UInt64
    public let startMicroseconds: UInt32
    public init(pid: Int32, startSeconds: UInt64, startMicroseconds: UInt32) {
        self.pid = pid; self.startSeconds = startSeconds; self.startMicroseconds = startMicroseconds
    }
    public var valid: Bool { pid > 0 && startSeconds > 0 && startMicroseconds < 1_000_000 }
    public var token: String { "\(pid):\(startSeconds):\(startMicroseconds)" }
    public func startedBefore(_ other: AppProcessKey) -> Bool {
        startSeconds < other.startSeconds ||
            (startSeconds == other.startSeconds && startMicroseconds < other.startMicroseconds)
    }
}

public struct AppProcessSnapshot: Codable, Equatable {
    public let key: AppProcessKey
    public let parentPID: Int32
    public let uid: UInt32
    public let executable: String
    public init(key: AppProcessKey, parentPID: Int32, uid: UInt32, executable: String) {
        self.key = key; self.parentPID = parentPID; self.uid = uid; self.executable = executable
    }
    /// PPID may change when a parent exits. It is ancestry evidence at admission,
    /// not a substitute for this process's immutable PID/start identity.
    public func sameProcess(as other: Self) -> Bool {
        key == other.key && uid == other.uid && executable == other.executable
    }
}

public struct AppGUIObservation: Equatable {
    public let pid: Int32
    public let bundlePath: String
    public let bundleID: String
    public let executable: String
    public let regular: Bool
    public init(pid: Int32, bundlePath: String, bundleID: String, executable: String, regular: Bool) {
        self.pid = pid; self.bundlePath = bundlePath; self.bundleID = bundleID
        self.executable = executable; self.regular = regular
    }
}

public struct AppProcessCensus {
    public let processes: [AppProcessSnapshot]
    public let applications: [AppGUIObservation]
    public let complete: Bool
    public init(processes: [AppProcessSnapshot], applications: [AppGUIObservation], complete: Bool) {
        self.processes = processes; self.applications = applications; self.complete = complete
    }
}

/// Closed diagnostic codes, deliberately separate from the mailbox's existing
/// APP_SERVICE_LAUNCH_UNKNOWN / APP_SERVICE_QUIT_UNKNOWN outcome classification.
public enum AppLaunchIdentityError: String, Error {
    case invalidPlan = "LAUNCH_PLAN_INVALID"
    case censusUnavailable = "PROCESS_CENSUS_UNAVAILABLE"
    case censusChanged = "PROCESS_CENSUS_CHANGED"
    case preexisting = "PREEXISTING_BUNDLE_PROCESS"
    case staleIdentity = "PREEXISTING_OR_RECYCLED_PID"
    case returnedOutside = "RETURNED_PROCESS_OUTSIDE_ACCEPTED_TREE"
    case returnedChanged = "RETURNED_PROCESS_IDENTITY_CHANGED"
    case metadataMismatch = "GUI_METADATA_MISMATCH"
    case noPrimary = "GUI_PRIMARY_NOT_OBSERVED"
    case ambiguousPrimary = "GUI_PRIMARY_AMBIGUOUS"
    case ancestryUnconfirmed = "PROCESS_ANCESTRY_UNCONFIRMED"
    case unrelatedRoot = "UNRELATED_BUNDLE_PROCESS"
    case changedIdentity = "OWNED_PROCESS_IDENTITY_CHANGED"
    case observationUnavailable = "ORIGINAL_PROCESS_OBSERVATION_UNAVAILABLE"
    case exitUnconfirmed = "ORIGINAL_PROCESS_EXIT_UNCONFIRMED"
}

public struct AppLaunchBinding: Equatable {
    public let root: AppProcessSnapshot
    public let primary: AppProcessSnapshot
    public let primaryBundle: AppLaunchPlan.GUIBundle
    /// Ordered primary -> accepted parents -> original launch root.
    public let ancestry: [AppProcessSnapshot]
    public let descendants: [AppProcessSnapshot]
    public init(root: AppProcessSnapshot, primary: AppProcessSnapshot,
                primaryBundle: AppLaunchPlan.GUIBundle, ancestry: [AppProcessSnapshot],
                descendants: [AppProcessSnapshot]) {
        self.root = root; self.primary = primary; self.primaryBundle = primaryBundle
        self.ancestry = ancestry; self.descendants = descendants
    }
}

public enum AppProcessObservation: Equatable {
    case live(AppProcessSnapshot)
    case absent
    case unavailable
    /// An original, identity-qualified kernel registration delivered NOTE_EXIT.
    /// This does not assert that the numeric PID can never be reused afterwards.
    case originalExit(AppProcessKey)
}

public enum AppProcessLife: String, Codable {
    case running, exited, unknown
}

public enum AppLaunchIdentity {
    public static let contract = "terminal-mac.launch-identity/1"
    public static let maximumProcesses = 16_384
    public static let maximumApplications = 512
    public static let maximumBundleProcesses = 256
    public static let maximumAncestry = 32

    private static func index(_ census: AppProcessCensus) throws -> [Int32: AppProcessSnapshot] {
        guard census.complete, census.processes.count <= maximumProcesses,
              census.applications.count <= maximumApplications else {
            throw AppLaunchIdentityError.censusUnavailable
        }
        var result: [Int32: AppProcessSnapshot] = [:]
        for process in census.processes {
            guard process.key.valid, process.parentPID >= 0,
                  process.executable.hasPrefix("/"), process.executable.utf8.count <= 4096,
                  !process.executable.contains("\0"), result[process.key.pid] == nil else {
                throw AppLaunchIdentityError.censusUnavailable
            }
            result[process.key.pid] = process
        }
        guard Set(census.applications.map(\.pid)).count == census.applications.count else {
            throw AppLaunchIdentityError.censusUnavailable
        }
        return result
    }

    public static func preflight(plan: AppLaunchPlan, census: AppProcessCensus) throws {
        let entries = try index(census)
        // Any process inside this exact tree is a predecessor, not only a GUI
        // process with the outer bundle ID. This catches a running launcher,
        // a nested Electron primary, updater and renderer descendants alike.
        guard !entries.values.contains(where: { plan.contains($0.executable) }),
              !census.applications.contains(where: {
                  plan.contains($0.executable) || plan.containsBundle($0.bundlePath)
              }) else { throw AppLaunchIdentityError.preexisting }
    }

    /// Binds the one LaunchServices-returned process to the one regular GUI
    /// primary and the accepted executable ancestor chain. Bundle ID alone,
    /// PID alone, or temporal proximity alone never supply this association.
    public static func bind(plan: AppLaunchPlan, before: AppProcessCensus,
                            after: AppProcessCensus, returned: AppProcessKey,
                            notBefore: AppProcessKey, uid: UInt32) throws -> AppLaunchBinding {
        try preflight(plan: plan, census: before)
        let prior = try index(before), current = try index(after)
        guard returned.valid, notBefore.valid,
              let returnedProcess = current[returned.pid], returnedProcess.key == returned else {
            throw AppLaunchIdentityError.returnedChanged
        }
        guard plan.acceptsExecutable(returnedProcess.executable) else {
            throw AppLaunchIdentityError.returnedOutside
        }
        let bundle = current.values.filter { plan.contains($0.executable) }
        guard bundle.count <= maximumBundleProcesses else { throw AppLaunchIdentityError.censusUnavailable }
        for process in bundle {
            guard plan.acceptsExecutable(process.executable), process.uid == uid else {
                throw AppLaunchIdentityError.returnedOutside
            }
            // Even a PID recycled since the baseline is not adopted. Its
            // original launch relationship was not observed by this owner.
            guard prior[process.key.pid] == nil, !process.key.startedBefore(notBefore) else {
                throw AppLaunchIdentityError.staleIdentity
            }
        }
        var candidates: [(AppProcessSnapshot, AppLaunchPlan.GUIBundle)] = []
        var launcherMetadata: [Int32] = []
        for app in after.applications where app.regular {
            guard plan.contains(app.executable) || plan.containsBundle(app.bundlePath) else { continue }
            if let process = current[app.pid], plan.isOuterLauncherMetadata(app, process: process) {
                launcherMetadata.append(process.key.pid)
                continue
            }
            guard let process = current[app.pid], process.executable == app.executable,
                  let expected = plan.guiBundle(path: app.bundlePath, identifier: app.bundleID,
                                                executable: app.executable) else {
                throw AppLaunchIdentityError.metadataMismatch
            }
            candidates.append((process, expected))
        }
        guard !candidates.isEmpty else { throw AppLaunchIdentityError.noPrimary }
        guard candidates.count == 1 else { throw AppLaunchIdentityError.ambiguousPrimary }
        let (primary, gui) = candidates[0]

        func acceptedChain(from first: AppProcessSnapshot) throws -> [AppProcessSnapshot] {
            var chain = [first]
            var seen: Set<Int32> = [first.key.pid]
            while let last = chain.last, let parent = current[last.parentPID], plan.contains(parent.executable) {
                guard chain.count < maximumAncestry, seen.insert(parent.key.pid).inserted,
                      plan.acceptsExecutable(parent.executable), parent.uid == uid,
                      !last.key.startedBefore(parent.key) else {
                    throw AppLaunchIdentityError.ancestryUnconfirmed
                }
                chain.append(parent)
            }
            return chain
        }
        let primaryChain = try acceptedChain(from: primary)
        guard let root = primaryChain.last,
              primaryChain.contains(where: { $0.key == returned }) else {
            throw AppLaunchIdentityError.ancestryUnconfirmed
        }
        guard launcherMetadata.allSatisfy({ pid in
            primaryChain.dropFirst().contains(where: { $0.key.pid == pid })
        }) else { throw AppLaunchIdentityError.ancestryUnconfirmed }
        // A nested bundle cannot be treated as an outer direct app just because
        // its accepted parent vanished before we could observe the relationship.
        guard gui.bundleRelativePath.isEmpty || primaryChain.count > 1 else {
            throw AppLaunchIdentityError.ancestryUnconfirmed
        }
        // Conversely, an outer GUI must run its declared executable. Script ->
        // native launcher roots are accepted only with a verified child chain.
        if primaryChain.count == 1 && primary.executable != plan.outerExecutable {
            throw AppLaunchIdentityError.ancestryUnconfirmed
        }
        for process in bundle {
            guard try acceptedChain(from: process).last?.key == root.key else {
                throw AppLaunchIdentityError.unrelatedRoot
            }
        }
        let descendants = bundle.filter { $0.key != root.key && $0.key != primary.key }
            .sorted { $0.key.pid < $1.key.pid }
        return AppLaunchBinding(root: root, primary: primary, primaryBundle: gui,
                                ancestry: primaryChain, descendants: descendants)
    }

    public static func requireSameBinding(_ expected: AppLaunchBinding, _ observed: AppLaunchBinding) throws {
        guard observed.root.sameProcess(as: expected.root),
              observed.primary.sameProcess(as: expected.primary),
              observed.primaryBundle == expected.primaryBundle,
              observed.ancestry.count == expected.ancestry.count,
              zip(observed.ancestry, expected.ancestry).allSatisfy({ pair in pair.0.sameProcess(as: pair.1) }) else {
            throw AppLaunchIdentityError.changedIdentity
        }
    }

    /// A process that crashed/exited before the request is not evidence of a
    /// successful normal Quit. No signal is sent to an absent/recycled primary.
    public static func requireNormalQuitAdmission(root: AppProcessLife, primary: AppProcessLife) throws {
        guard root == .running, primary == .running else { throw AppLaunchIdentityError.exitUnconfirmed }
    }

    /// Only an exit event registered against the original identity proves that
    /// process exited. Absence, elapsed time or a different start identity do not.
    public static func life(of expected: AppProcessSnapshot, observation: AppProcessObservation) -> AppProcessLife {
        switch observation {
        case .live(let actual): return actual.sameProcess(as: expected) ? .running : .unknown
        case .originalExit(let key): return key == expected.key ? .exited : .unknown
        case .absent, .unavailable: return .unknown
        }
    }
}
