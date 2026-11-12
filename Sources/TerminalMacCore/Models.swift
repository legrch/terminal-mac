import CryptoKit
import Foundation

public struct Failure: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Who can prove what about a failed operation, classified by the side that ran it before the
/// outcome crossed the mailbox. An absent classification (an old helper, a plain error) proves
/// nothing and must be treated as if an effect may have happened.
public enum GuestOutcome: String, Codable, Sendable {
    /// Failed before any guest or host effect could start.
    case noEffect
    /// A clipboard copy ended without changing the host clipboard; the transfer did not happen.
    case confirmedNoCopy
    /// An effect may have started; nobody can prove otherwise.
    case mutationUnknown
}

public struct OutcomeFailure: LocalizedError {
    public let message: String
    public let outcome: GuestOutcome
    /// Content-free diagnostics for a failure (never authority, never replayed).
    public let values: [String: String]
    public init(_ message: String, outcome: GuestOutcome, values: [String: String] = [:]) {
        self.message = message; self.outcome = outcome; self.values = values
    }
    public var errorDescription: String? { message }
}

/// What a failed in-flight guest action means for the input queued behind it. Known no-effect and
/// confirmed-no-copy failures keep the queued input in order; anything unresolved stops the queue,
/// because a later command could interleave with an effect nobody can account for. A stop never
/// replays the failed action and never claims the guest is clean.
public enum InputQueueDisposition: Equatable { case proceed, stop }

public enum InputQueue {
    public static func disposition(for error: Error) -> InputQueueDisposition {
        switch error {
        // A timeout is never a known outcome: even an apparently unread request does not prove
        // absence of effects across a virtio-fs exchange, so every timeout stops the queue.
        case is MailboxTimeout: return .stop
        case let failure as OutcomeFailure: return failure.outcome == .mutationUnknown ? .stop : .proceed
        default: return .stop
        }
    }
}

public struct Arguments {
    public var positionals: [String] = []
    public var options: [String: String] = [:]
    public var flags: Set<String> = []
    public init(_ input: [String], flags allowedFlags: Set<String> = [], options allowedOptions: Set<String> = []) throws {
        var i = 0
        while i < input.count {
            let item = input[i]
            if item == "--" { positionals += input.dropFirst(i + 1); break }
            if item.hasPrefix("--") {
                let name = String(item.dropFirst(2))
                guard !flags.contains(name), options[name] == nil else { throw Failure("Duplicate option: \(item)") }
                if allowedFlags.contains(name) { flags.insert(name) }
                else if allowedOptions.contains(name) {
                    i += 1
                    guard i < input.count, !input[i].hasPrefix("--") else { throw Failure("Missing value for \(item)") }
                    options[name] = input[i]
                } else { throw Failure("Unknown option: \(item)") }
            } else { positionals.append(item) }
            i += 1
        }
    }
    public func integer(_ key: String, default fallback: Int, range: ClosedRange<Int>) throws -> Int {
        guard let raw = options[key] else { return fallback }
        guard let value = Int(raw), range.contains(value) else { throw Failure("--\(key) must be in \(range)") }
        return value
    }
    public func machineName() throws -> String {
        guard positionals.count <= 1 else { throw Failure("Expected one VM name") }
        let name = positionals.first ?? "default"
        try validateName(name)
        return name
    }
}

public func validateName(_ name: String) throws {
    guard name.range(of: "^[a-zA-Z0-9][a-zA-Z0-9_-]{0,47}$", options: .regularExpression) != nil else {
        throw Failure("VM names must be 1–48 letters, numbers, underscores or hyphens, starting with a letter or number")
    }
}

public struct Machine: Codable {
    public var name: String
    public var cpu: Int
    public var memoryGiB: Int
    public var diskGiB: Int
    public var width: Int
    public var height: Int
    public var network: Bool
    public var installed: Bool
    /// 2 renders the guest at Retina density: twice the pixels for the same point size. Older VMs have none.
    public var scale: Int?
    public var displayScale: Int { scale == 2 ? 2 : 1 }
    public init(name: String, cpu: Int, memoryGiB: Int, diskGiB: Int, width: Int = 1280, height: Int = 800, network: Bool = true, installed: Bool = false, scale: Int? = nil) {
        self.name = name; self.cpu = cpu; self.memoryGiB = memoryGiB; self.diskGiB = diskGiB
        self.width = width; self.height = height; self.network = network; self.installed = installed; self.scale = scale
    }
}

public struct Request: Codable {
    public let id: UUID
    public let action: String
    public let arguments: [String: String]
    public let deadline: Date
    public func requireLive(at now: Date = Date()) throws {
        guard deadline > now else { throw OutcomeFailure("Request expired before execution", outcome: .noEffect) }
    }
    public init(action: String, arguments: [String: String] = [:], timeout: TimeInterval = 15) {
        id = UUID(); self.action = action; self.arguments = arguments; deadline = Date().addingTimeInterval(timeout)
    }
}

public struct Reply: Codable {
    public let id: UUID
    public let ok: Bool
    public let values: [String: String]
    public let error: String?
    /// Set on failure replies by helpers that classify outcomes; absent means unclassified.
    public let outcome: GuestOutcome?
    public init(id: UUID, values: [String: String] = [:], error: String? = nil, outcome: GuestOutcome? = nil) {
        self.id = id; ok = error == nil; self.values = values; self.error = error; self.outcome = outcome
    }
}

public struct Store {
    public let root: URL
    public init(root: URL? = nil) {
        self.root = root ?? ProcessInfo.processInfo.environment["TERMINAL_MAC_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/terminal-mac")
    }
    public func directory(_ name: String) throws -> URL {
        try validateName(name)
        return root.appendingPathComponent("machines").appendingPathComponent(name)
    }
    public func load(_ name: String) throws -> Machine {
        let url = try directory(name).appendingPathComponent("machine.json")
        guard FileManager.default.fileExists(atPath: url.path) else { throw Failure("VM '\(name)' does not exist. Run terminal-mac create \(name) --ipsw /path/to/restore.ipsw") }
        let machine = try JSONDecoder().decode(Machine.self, from: Data(contentsOf: url))
        guard machine.name == name else {
            throw Failure("Interrupted rename: '\(name)' declares machine name '\(machine.name)'. Complete or undo it manually before using this machine.")
        }
        return machine
    }
    public func save(_ machine: Machine) throws {
        let data = try JSONEncoder().encode(machine)
        try data.write(to: directory(machine.name).appendingPathComponent("machine.json"), options: .atomic)
    }

    /// Same-volume directory rename that preserves identity, disks, auxiliary state and guest
    /// data. Refuses running machines, held input leases and collisions; the directory move is
    /// atomic, metadata completes before the receipt is published, and an interrupted state is
    /// detected instead of silently adopted. Historical evidence inside the machine directory
    /// moves unchanged; the receipt records the old→new mapping.
    public func rename(_ from: String, to: String) throws {
        try validateName(from)
        try validateName(to)
        guard from != to else { throw Failure("Renaming '\(from)' to itself changes nothing") }
        let source = try directory(from)
        guard FileManager.default.fileExists(atPath: source.appendingPathComponent("machine.json").path) else {
            throw Failure("VM '\(from)' does not exist")
        }
        _ = try load(from)
        let destination = try directory(to)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw Failure("VM '\(to)' already exists; rename refuses collisions")
        }
        let lock = open(source.appendingPathComponent("runtime.lock").path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw Failure("Cannot verify '\(from)' is stopped") }
        var running = false
        if flock(lock, LOCK_EX | LOCK_NB) == 0 { flock(lock, LOCK_UN) } else { running = true }
        close(lock)
        guard !running else { throw Failure("VM '\(from)' is running. Stop it with: terminal-mac stop \(from)") }
        switch try InputLease.probe(directory: source) {
        case .free: break
        case .held(let owner, _):
            throw Failure("Guest input is locked by \(owner); wait for it to finish before renaming")
        case .heldUnknown:
            throw Failure("Guest input is locked by another client with unavailable identity; refuse renaming")
        case .unresolved:
            throw Failure("Previous guest input operation is unresolved; refuse renaming until retained evidence is reconciled")
        }
        guard Darwin.rename(source.path, destination.path) == 0 else {
            throw Failure("Cannot rename machine directory: \(String(cString: strerror(errno)))")
        }
        try Self.completeRename(destination: destination, from: from, to: to)
    }

    /// Metadata completion for a directory that has already moved. Interrupted states surface
    /// here with their recovery instead of being adopted as a ready machine.
    static func completeRename(destination: URL, from: String, to: String) throws {
        var machine = try JSONDecoder().decode(Machine.self, from: Data(contentsOf: destination.appendingPathComponent("machine.json")))
        guard machine.name == from else {
            throw Failure("Interrupted rename: '\(destination.lastPathComponent)' still declares machine name '\(machine.name)'. Complete or undo it manually before using this machine.")
        }
        machine.name = to
        let data = try JSONEncoder().encode(machine)
        try data.write(to: destination.appendingPathComponent("machine.json"), options: .atomic)
        let receipt: [String: Any] = ["schema": "terminal-mac.rename/1", "from": from, "to": to,
                                      "at": Int(Date().timeIntervalSince1970)]
        let json = try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let receiptURL = destination.appendingPathComponent("rename.json")
        try json.write(to: receiptURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: receiptURL.path)
    }

    /// Stopped-machine clone: an independent clean instance with a fresh VM identity, duplicated
    /// auxiliary state and a copy-on-write disk where the filesystem supports it. Refuses running
    /// machines, held input leases and collisions; the source is never mutated and the
    /// destination is created new or not at all. The receipt binds provenance: a COW clone's
    /// disk bytes equal the source disk at clone time.
    public func clone(from: String, to: String, identityData: Data, offline: Bool = false) throws {
        try validateName(from)
        try validateName(to)
        guard from != to else { throw Failure("Cloning '\(from)' to itself changes nothing") }
        guard !identityData.isEmpty else { throw Failure("Clone needs a non-empty VM identity") }
        let source = try directory(from)
        guard FileManager.default.fileExists(atPath: source.appendingPathComponent("machine.json").path) else {
            throw Failure("VM '\(from)' does not exist")
        }
        let destination = try directory(to)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw Failure("VM '\(to)' already exists; clone refuses collisions")
        }
        let lock = open(source.appendingPathComponent("runtime.lock").path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw Failure("Cannot verify '\(from)' is stopped") }
        var running = false
        if flock(lock, LOCK_EX | LOCK_NB) == 0 { flock(lock, LOCK_UN) } else { running = true }
        close(lock)
        guard !running else { throw Failure("VM '\(from)' is running. Stop it with: terminal-mac stop \(from)") }
        switch try InputLease.probe(directory: source) {
        case .free: break
        case .held(let owner, _):
            throw Failure("Guest input is locked by \(owner); wait for it to finish before cloning")
        case .heldUnknown:
            throw Failure("Guest input is locked by another client with unavailable identity; refuse cloning")
        case .unresolved:
            throw Failure("Previous guest input operation is unresolved; refuse cloning until retained evidence is reconciled")
        }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        // The destination is new, so any failure removes the partial directory instead of leaving it.
        do { try Self.copyMachine(from: from, to: to, source: source, destination: destination,
                                  identityData: identityData, offline: offline) }
        catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    static func copyMachine(from: String, to: String, source: URL, destination: URL,
                            identityData: Data, offline: Bool) throws {
        // Hash the source disk first: it proves readability and binds provenance before anything is written.
        let diskDigest = try fileDigest(source.appendingPathComponent("disk.img"))
        try copyStateFile("disk.img", from: source, to: destination, clonable: true)
        try copyStateFile("auxiliary.bin", from: source, to: destination, clonable: true)
        try copyStateFile("hardware.bin", from: source, to: destination, clonable: false)
        try copyStateFile("machine.json", from: source, to: destination, clonable: false)
        try writeDurable(identityData, at: destination.appendingPathComponent("identity.bin"))
        var machine = try JSONDecoder().decode(Machine.self, from: Data(contentsOf: destination.appendingPathComponent("machine.json")))
        machine.name = to
        if offline { machine.network = false }
        try writeDurable(JSONEncoder().encode(machine), at: destination.appendingPathComponent("machine.json"))
        let receipt: [String: Any] = ["schema": "terminal-mac.clone/1", "from": from, "to": to,
                                      "identitySha256": sha256Hex(identityData), "diskSha256Source": diskDigest,
                                      "at": Int(Date().timeIntervalSince1970)]
        let json = try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try writeDurable(json, at: destination.appendingPathComponent("clone.json"))
        try syncDirectory(destination)
    }

    /// One state file. Large images prefer clonefile(2): same-volume APFS gives copy-on-write, so
    /// the clone's bytes equal the source at clone time; anything clonefile refuses falls back to
    /// a bounded streamed copy. Sources must be plain regular files — clonefile would happily
    /// duplicate a whole directory tree, so a stray directory or symlink fails closed instead.
    private static func copyStateFile(_ name: String, from source: URL, to destination: URL, clonable: Bool) throws {
        let sourceURL = source.appendingPathComponent(name)
        var info = stat()
        guard lstat(sourceURL.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw Failure("Cannot copy \(name): not a regular file")
        }
        if clonable, Darwin.clonefile(sourceURL.path, destination.appendingPathComponent(name).path, 0) == 0 { return }
        try streamFile(named: name, from: sourceURL, to: destination.appendingPathComponent(name))
    }

    /// 64 KiB chunks, fsync of the destination file, then a source/destination size match —
    /// a short or truncated copy is refused, never adopted.
    private static func streamFile(named name: String, from source: URL, to destination: URL) throws {
        let input = open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard input >= 0 else { throw Failure("Cannot copy \(name): \(String(cString: strerror(errno)))") }
        defer { close(input) }
        let output = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw Failure("Cannot copy \(name): \(String(cString: strerror(errno)))") }
        do {
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            try buffer.withUnsafeMutableBytes { bytes in
                while true {
                    let count = Darwin.read(input, bytes.baseAddress, bytes.count)
                    if count < 0 {
                        if errno == EINTR { continue }
                        throw Failure("Cannot copy \(name): \(String(cString: strerror(errno)))")
                    }
                    guard count > 0 else { break }
                    var offset = 0
                    while offset < count {
                        let written = Darwin.write(output, bytes.baseAddress!.advanced(by: offset), count - offset)
                        if written < 0 && errno == EINTR { continue }
                        guard written > 0 else { throw Failure("Cannot copy \(name): \(String(cString: strerror(errno)))") }
                        offset += written
                    }
                }
            }
            guard fsync(output) == 0 else { throw Failure("Cannot copy \(name): cannot sync") }
            var sourceInfo = stat(), destinationInfo = stat()
            guard fstat(input, &sourceInfo) == 0, fstat(output, &destinationInfo) == 0,
                  sourceInfo.st_size == destinationInfo.st_size else {
                throw Failure("Cannot copy \(name): size mismatch after copy")
            }
        } catch {
            close(output)
            unlink(destination.path)
            throw error
        }
        close(output)
    }

    private static func fileDigest(_ url: URL) throws -> String {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Failure("Cannot hash \(url.lastPathComponent): \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw Failure("Cannot hash \(url.lastPathComponent): not a regular file")
        }
        var digest = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        try buffer.withUnsafeMutableBytes { bytes in
            while true {
                let count = Darwin.read(fd, bytes.baseAddress, bytes.count)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw Failure("Cannot hash \(url.lastPathComponent): \(String(cString: strerror(errno)))")
                }
                guard count > 0 else { break }
                digest.update(bufferPointer: UnsafeRawBufferPointer(start: bytes.baseAddress, count: count))
            }
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Create-or-replace a small file atomically: temp file, fsync, rename, directory entry sync.
    private static func writeDurable(_ data: Data, at url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent("." + UUID().uuidString + ".tmp")
        let output = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw Failure("Cannot write \(url.lastPathComponent): \(String(cString: strerror(errno)))") }
        do {
            try writeAll(output, data, name: url.lastPathComponent)
            guard fsync(output) == 0 else { throw Failure("Cannot sync \(url.lastPathComponent)") }
        } catch {
            close(output)
            unlink(temporary.path)
            throw error
        }
        close(output)
        guard Darwin.rename(temporary.path, url.path) == 0 else {
            unlink(temporary.path)
            throw Failure("Cannot publish \(url.lastPathComponent)")
        }
        try syncDirectory(url.deletingLastPathComponent())
    }

    private static func writeAll(_ fd: Int32, _ data: Data, name: String) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw Failure("Cannot write \(name)") }
                offset += count
            }
        }
    }

    private static func syncDirectory(_ directory: URL) throws {
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Failure("Cannot sync directory: \(String(cString: strerror(errno)))") }
        let synced = fsync(fd)
        close(fd)
        guard synced == 0 else { throw Failure("Cannot sync directory: \(String(cString: strerror(errno)))") }
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
