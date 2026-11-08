import Foundation
import Darwin

/// Host-side exclusive guest-input ownership for one machine.
///
/// The flock file is the authority: the kernel releases the lock when a holder crashes, so the
/// lease self-heals. The sibling JSON is evidence metadata (owner, generation, acquisition time)
/// and never grants anything on its own. Consumers that cannot use this class — a product
/// scenario in another language, for example — acquire the same lock file with the same flock
/// semantics and write the same metadata shape; that published file contract is the cross-runtime
/// interface, deliberately not a daemon or RPC.
public struct LeaseConflict: LocalizedError {
    public let owner: String?
    public init(owner: String?) { self.owner = owner }
    public var errorDescription: String? {
        "Guest input is locked by \(owner ?? "another client"); wait for it to finish"
    }
}

public final class InputLease {
    public static let lockName = "input-lease.lock"
    public static let metadataName = "input-lease.json"
    public static let schema = "terminal-mac.input-lease/1"

    public struct Metadata: Codable, Equatable {
        public let schema: String
        public let owner: String
        public let generation: Int
        public let acquiredAt: Int
    }

    public let owner: String
    public let generation: Int
    private let directory: URL
    private var fd: Int32
    private var released = false

    private init(directory: URL, fd: Int32, owner: String, generation: Int) {
        self.directory = directory
        self.fd = fd
        self.owner = owner
        self.generation = generation
    }

    public static func validate(owner: String) throws {
        guard !owner.isEmpty, owner.utf8.count <= 128,
              owner.allSatisfy({ c in c.isASCII && (c.isLetter || c.isNumber || "-_.:".contains(c)) }) else {
            throw Failure("Lease owner must be 1-128 letters, numbers, hyphens, dots, underscores or colons")
        }
    }

    /// Acquire the exclusive lease or fail before any guest effect with the current holder.
    public static func acquire(directory: URL, owner: String, generation: Int) throws -> InputLease {
        try validate(owner: owner)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(directory.appendingPathComponent(lockName).path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure("Cannot open input lease lock: \(String(cString: strerror(errno)))") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            let current = readMetadata(directory)
            throw LeaseConflict(owner: current?.owner)
        }
        do {
            let metadata = Metadata(schema: schema, owner: owner, generation: generation,
                                    acquiredAt: Int(Date().timeIntervalSince1970))
            try writeDurable(JSONEncoder().encode(metadata), at: directory.appendingPathComponent(metadataName))
        } catch {
            flock(fd, LOCK_UN)
            close(fd)
            throw error
        }
        return InputLease(directory: directory, fd: fd, owner: owner, generation: generation)
    }

    /// Release after in-flight work is resolved; idempotent. The caller owns the rule that an
    /// unresolved operation must not be abandoned — expiry of the metadata never clears effects.
    public func release() {
        guard !released else { return }
        released = true
        Self.removeDurable(directory: directory, name: Self.metadataName)
        flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }

    deinit {
        if !released && fd >= 0 { flock(fd, LOCK_UN); close(fd) }
    }

    /// The current holder, or nil when the lease is free. Read-only probe; never blocks.
    public static func holder(directory: URL) -> String? {
        let fd = open(directory.appendingPathComponent(lockName).path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return readMetadata(directory)?.owner ?? "unknown" }
        flock(fd, LOCK_UN)
        return nil
    }

    /// Who may publish guest input through the CLI when a lease is held. A scenario holding the
    /// run lease drives its own CLI child actions by presenting the same owner token; everyone
    /// else is refused before any request is written.
    public enum Admission: Equatable { case allowed, locked(owner: String) }
    public static func admission(holder: String?, claimedOwner: String?) -> Admission {
        guard let holder else { return .allowed }
        if let claimedOwner, claimedOwner == holder { return .allowed }
        return .locked(owner: holder)
    }

    /// Whether the VM process's native window may inject an event now. The lease holder that
    /// deliberately opened the window (owner sign-in during setup) stays interactive; a foreign
    /// holder makes the window demonstrably non-interactive.
    public static func nativeWindowAllowed(holder: String?, windowOwner: String?) -> Bool {
        holder == nil || holder == windowOwner
    }

    private static func readMetadata(_ directory: URL) -> Metadata? {
        let path = directory.appendingPathComponent(metadataName).path
        let input = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard input >= 0 else { return nil }
        defer { close(input) }
        var info = stat()
        guard fstat(input, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1, info.st_size > 0, info.st_size <= 4096 else { return nil }
        var data = Data(count: Int(info.st_size))
        let count = data.withUnsafeMutableBytes { mutable in Darwin.read(input, mutable.baseAddress, Int(info.st_size)) }
        guard count == Int(info.st_size), let metadata = try? JSONDecoder().decode(Metadata.self, from: data), metadata.schema == schema else { return nil }
        return metadata
    }

    /// fsync the metadata before rename and the directory entry after, so an acquired lease is
    /// visible after a crash. This is the connector-key-store ordering contract.
    static func writeDurable(_ data: Data, at url: URL) throws {
        let directory = url.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent("." + UUID().uuidString + ".tmp")
        let out = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard out >= 0 else { throw Failure("Cannot write lease metadata: \(String(cString: strerror(errno)))") }
        do {
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.write(out, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw Failure("Cannot write lease metadata") }
                    offset += count
                }
            }
            guard fsync(out) == 0 else { throw Failure("Cannot sync lease metadata") }
        } catch {
            close(out)
            unlink(temporary.path)
            throw error
        }
        close(out)
        guard rename(temporary.path, url.path) == 0 else {
            unlink(temporary.path)
            throw Failure("Cannot publish lease metadata")
        }
        syncDirectory(directory)
    }

    static func removeDurable(directory: URL, name: String) {
        // ENOENT only means the metadata was already gone; the entry sync still applies.
        unlink(directory.appendingPathComponent(name).path)
        syncDirectory(directory)
    }

    static func syncDirectory(_ directory: URL) {
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return }
        _ = fsync(fd)
        close(fd)
    }
}
