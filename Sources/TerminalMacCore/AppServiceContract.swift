import Foundation

/// A finite, compiled-in application lifecycle service, NOT a shell executor.
/// The payload manifest binds application data. It never selects server code,
/// an interpreter, environment, arguments, working directory, or script.
public enum AppServiceContract {
    // /4 also qualifies per-share read-only access and pins independently accepted verification policy and application bytes.
    // Older /1 cached-app helpers must never be accepted as installed QA.
    public static let version = "terminal-mac.app-service/4"
    public static let installationRoot = "/Applications"
    public static let installationLocation = "guest-applications/1"
    public static let payloadVersion = "terminal-mac.app-payload/1"
    public static let recordVersion = "terminal-mac.app-service-record/2"
    public static let maximumOperations = 64
    public static let lifetime: TimeInterval = 600
    public static let actions: Set<String> = ["open", "install", "observe", "launch", "activate", "quit", "close"]
    public static let argumentKeys: Set<String> = ["serviceCommand", "serviceRun", "serviceNonce", "serviceOperation", "serviceSequence", "serviceManifest", "serviceAcceptance", "leaseOwner"]
    public static let reasons: Set<String> = [
        "APP_SERVICE_INVALID", "APP_SERVICE_BINDING", "APP_SERVICE_BUSY",
        "APP_SERVICE_UNRESOLVED", "APP_SERVICE_EXPIRED", "APP_SERVICE_REPLAY",
        "APP_SERVICE_CUSTODY", "APP_SERVICE_PAYLOAD_INVALID", "APP_SERVICE_DIGEST",
        "APP_SERVICE_UNSAFE_PATH", "APP_SERVICE_IO", "APP_SERVICE_NOT_INSTALLED",
        "APP_SERVICE_RUNNING", "APP_SERVICE_NOT_RUNNING", "APP_SERVICE_APP_IDENTITY",
        "APP_SERVICE_INSTALLED_COLLISION",
        "APP_SERVICE_LAUNCH_UNKNOWN", "APP_SERVICE_QUIT_UNKNOWN", "APP_SERVICE_PUBLICATION_UNKNOWN"
    ]
    public static func refuse(_ reason: String) -> OutcomeFailure {
        OutcomeFailure(reasons.contains(reason) ? reason : "APP_SERVICE_INVALID", outcome: .noEffect)
    }
    public static func hex(_ value: String, count: Int) -> Bool {
        value.utf8.count == count && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    public static func run(_ value: String) -> Bool {
        value.hasPrefix("run-") && hex(String(value.dropFirst(4)), count: 32)
    }
    public static func operation(_ value: String) -> Bool {
        UUID(uuidString: value)?.uuidString.lowercased() == value
    }
    public static func owner(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 58, 95].contains($0)
        }
    }
    /// Intentionally narrow, portable application paths. Unicode/case aliases,
    /// traversal, NUL, control characters, slash alternatives and huge trees
    /// are refused rather than normalized into a different target.
    public static func path(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 1024,
              value.utf8.allSatisfy({ (32...126).contains($0) && $0 != 92 && $0 != 58 }) else { return false }
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count <= 32 && parts.allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255 && !$0.hasSuffix(" ")
        }
    }
}

public struct AppServiceCommand: Equatable {
    public let command: String
    public let runID: String
    public let nonce: String
    public let operationID: String
    public let sequence: Int
    public let manifestSHA256: String
    public let acceptanceSHA256: String
    public let owner: String

    public init(arguments: [String: String]) throws {
        guard Set(arguments.keys) == AppServiceContract.argumentKeys,
              let command = arguments["serviceCommand"], AppServiceContract.actions.contains(command),
              let run = arguments["serviceRun"], AppServiceContract.run(run),
              let nonce = arguments["serviceNonce"], AppServiceContract.hex(nonce, count: 64),
              let operation = arguments["serviceOperation"], AppServiceContract.operation(operation),
              let rawSequence = arguments["serviceSequence"], let sequence = Int(rawSequence),
              String(sequence) == rawSequence, (0...AppServiceContract.maximumOperations).contains(sequence),
              let digest = arguments["serviceManifest"], AppServiceContract.hex(digest, count: 64),
              let acceptance = arguments["serviceAcceptance"], AppServiceContract.hex(acceptance, count: 64),
              let owner = arguments["leaseOwner"], AppServiceContract.owner(owner),
              command != "open" || sequence == 0 else { throw AppServiceContract.refuse("APP_SERVICE_INVALID") }
        self.command = command; runID = run; self.nonce = nonce
        operationID = operation; self.sequence = sequence
        manifestSHA256 = digest; acceptanceSHA256 = acceptance; self.owner = owner
    }
}

/// Persisted before and after every effect. An interrupted pending/unknown
/// record is never adopted by another helper instance or cleared on expiry.
public struct AppServiceRecord: Codable, Equatable {
    public let schema: String
    public let runID: String
    public let nonce: String
    public let owner: String
    public let manifestSHA256: String
    public let acceptanceSHA256: String
    public let helperInstance: String
    public let expiresAt: Double
    public private(set) var phase: String
    public private(set) var sequence: Int
    public private(set) var operationID: String
    public private(set) var pending: String?
    public private(set) var operations: [String]
    public private(set) var appPID: Int32?

    public init(open: AppServiceCommand, helperInstance: String, now: Date) throws {
        guard open.command == "open", AppServiceContract.operation(helperInstance),
              now.timeIntervalSince1970.isFinite, now.timeIntervalSince1970 > 0 else {
            throw AppServiceContract.refuse("APP_SERVICE_INVALID")
        }
        schema = AppServiceContract.recordVersion; runID = open.runID
        nonce = open.nonce; owner = open.owner; manifestSHA256 = open.manifestSHA256
        acceptanceSHA256 = open.acceptanceSHA256
        self.helperInstance = helperInstance
        expiresAt = now.addingTimeInterval(AppServiceContract.lifetime).timeIntervalSince1970
        phase = "pending"; sequence = 0; operationID = open.operationID
        pending = "open"; operations = [open.operationID]; appPID = nil
    }

    public func validate() throws {
        guard schema == AppServiceContract.recordVersion, AppServiceContract.run(runID),
              AppServiceContract.hex(nonce, count: 64), AppServiceContract.owner(owner),
              AppServiceContract.hex(manifestSHA256, count: 64), AppServiceContract.hex(acceptanceSHA256, count: 64), AppServiceContract.operation(helperInstance),
              expiresAt.isFinite, expiresAt > 0,
              ["pending", "ready", "installed", "running", "closed", "unknown"].contains(phase),
              (0...AppServiceContract.maximumOperations).contains(sequence),
              !operations.isEmpty, operations.count <= AppServiceContract.maximumOperations + 1,
              operations.allSatisfy(AppServiceContract.operation), Set(operations).count == operations.count,
              operationID == operations.last, sequence + 1 == operations.count,
              appPID == nil || appPID! > 0,
              pending == nil || AppServiceContract.actions.contains(pending!),
              (phase == "pending") == (pending != nil),
              phase != "closed" || appPID == nil else { throw AppServiceContract.refuse("APP_SERVICE_UNRESOLVED") }
    }

    public func requireBinding(_ request: AppServiceCommand) throws {
        try validate()
        guard request.runID == runID, request.nonce == nonce, request.owner == owner,
              request.manifestSHA256 == manifestSHA256, request.acceptanceSHA256 == acceptanceSHA256 else { throw AppServiceContract.refuse("APP_SERVICE_BINDING") }
    }

    public mutating func begin(_ request: AppServiceCommand, now: Date, activeOwner: String?) throws {
        try requireBinding(request)
        guard activeOwner == owner else { throw AppServiceContract.refuse("APP_SERVICE_CUSTODY") }
        guard pending == nil, phase != "unknown", phase != "closed" else { throw AppServiceContract.refuse("APP_SERVICE_UNRESOLVED") }
        guard request.command != "open", request.command != "observe",
              request.sequence == sequence + 1, !operations.contains(request.operationID),
              operations.count <= AppServiceContract.maximumOperations else { throw AppServiceContract.refuse("APP_SERVICE_REPLAY") }
        // Expiry prevents new work, but not explicit bounded normal shutdown.
        guard now.timeIntervalSince1970 < expiresAt || ["quit", "close"].contains(request.command) else {
            throw AppServiceContract.refuse("APP_SERVICE_EXPIRED")
        }
        switch request.command {
        case "install": guard phase == "ready" else { throw AppServiceContract.refuse("APP_SERVICE_INVALID") }
        case "launch": guard phase == "installed" else { throw AppServiceContract.refuse("APP_SERVICE_NOT_INSTALLED") }
        case "activate", "quit": guard phase == "running" else { throw AppServiceContract.refuse("APP_SERVICE_NOT_RUNNING") }
        case "close": guard appPID == nil else { throw AppServiceContract.refuse("APP_SERVICE_RUNNING") }
        default: throw AppServiceContract.refuse("APP_SERVICE_INVALID")
        }
        sequence = request.sequence; operationID = request.operationID; operations.append(request.operationID)
        pending = request.command; phase = "pending"
    }

    public mutating func complete(_ command: String, pid: Int32? = nil) throws {
        guard pending == command, phase == "pending" else { throw AppServiceContract.refuse("APP_SERVICE_UNRESOLVED") }
        switch command {
        case "open": phase = "ready"
        case "install": phase = "installed"
        case "launch", "activate":
            guard let pid, pid > 0 else { throw AppServiceContract.refuse("APP_SERVICE_APP_IDENTITY") }
            phase = "running"; appPID = pid
        case "quit": phase = "installed"; appPID = nil
        case "close": phase = "closed"; appPID = nil
        default: throw AppServiceContract.refuse("APP_SERVICE_INVALID")
        }
        pending = nil
    }
    public mutating func markUnknown() { phase = "unknown"; pending = nil }
}

public struct AppServicePayload: Codable {
    public struct Entry: Codable {
        public let path: String
        public let kind: String
        public let mode: Int
        public let bytes: Int
        public let sha256: String
        public let blob: String
        public let target: String
    }
    public let schema: String
    public let appName: String
    public let bundleID: String
    public let version: String
    public let artifactSHA256: String
    public let archiveSHA256: String
    public let entries: [Entry]

    public func validate() throws {
        guard schema == AppServiceContract.payloadVersion,
              AppServiceContract.path(appName), !appName.contains("/"), appName.hasSuffix(".app"),
              appName.count > 4, !appName.hasPrefix("."),
              !bundleID.isEmpty, bundleID.utf8.count <= 160,
              bundleID.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46].contains($0) }),
              !version.isEmpty, version.utf8.count <= 64,
              version.utf8.allSatisfy({ (48...57).contains($0) || [45, 46].contains($0) }),
              AppServiceContract.hex(artifactSHA256, count: 64), AppServiceContract.hex(archiveSHA256, count: 64),
              !entries.isEmpty, entries.count <= 25000 else { throw AppServiceContract.refuse("APP_SERVICE_PAYLOAD_INVALID") }
        var paths: [String: String] = [:]; var aliases = Set<String>(); var total: UInt64 = 0
        for entry in entries {
            guard AppServiceContract.path(entry.path), paths[entry.path] == nil,
                  aliases.insert(entry.path.lowercased()).inserted,
                  (0...0o777).contains(entry.mode), ["directory", "file", "symlink"].contains(entry.kind) else {
                throw AppServiceContract.refuse("APP_SERVICE_PAYLOAD_INVALID")
            }
            paths[entry.path] = entry.kind
            if entry.kind == "file" {
                guard (0...2_147_483_648).contains(entry.bytes), AppServiceContract.hex(entry.sha256, count: 64),
                      entry.blob == "blob-" + entry.sha256, entry.target.isEmpty else { throw AppServiceContract.refuse("APP_SERVICE_PAYLOAD_INVALID") }
                total += UInt64(entry.bytes)
                guard total <= 4_294_967_296 else { throw AppServiceContract.refuse("APP_SERVICE_PAYLOAD_INVALID") }
            } else {
                guard entry.bytes == 0, entry.sha256.isEmpty, entry.blob.isEmpty,
                      entry.kind == "symlink" || entry.target.isEmpty else { throw AppServiceContract.refuse("APP_SERVICE_PAYLOAD_INVALID") }
            }
        }
        guard paths["Contents"] == "directory", paths["Contents/Info.plist"] == "file" else {
            throw AppServiceContract.refuse("APP_SERVICE_PAYLOAD_INVALID")
        }
        let links = Dictionary(uniqueKeysWithValues: entries.filter { $0.kind == "symlink" }.map { ($0.path, $0.target) })
        // Resolve each component, including a symlink in the middle of a target
        // (e.g. Versions/Current/Resources). Only declared nodes are reachable.
        func resolve(_ relative: String) throws {
            var pending = relative.split(separator: "/").map(String.init)
            var resolved: [String] = []
            var visited = Set<String>()
            var hops = 0
            while !pending.isEmpty {
                let component = pending.removeFirst()
                let candidate = (resolved + [component]).joined(separator: "/")
                guard let kind = paths[candidate] else { throw AppServiceContract.refuse("APP_SERVICE_UNSAFE_PATH") }
                if kind == "symlink" {
                    guard let target = links[candidate], AppServiceContract.path(target),
                          visited.insert(candidate).inserted, hops < 40 else {
                        throw AppServiceContract.refuse("APP_SERVICE_UNSAFE_PATH")
                    }
                    hops += 1
                    pending = target.split(separator: "/").map(String.init) + pending
                } else {
                    guard pending.isEmpty || kind == "directory" else { throw AppServiceContract.refuse("APP_SERVICE_UNSAFE_PATH") }
                    resolved.append(component)
                }
            }
        }
        for entry in entries {
            var parts = entry.path.split(separator: "/").map(String.init)
            parts.removeLast()
            while !parts.isEmpty {
                guard paths[parts.joined(separator: "/")] == "directory" else { throw AppServiceContract.refuse("APP_SERVICE_UNSAFE_PATH") }
                parts.removeLast()
            }
            if entry.kind == "symlink" { try resolve(entry.path) }
        }
    }
}
