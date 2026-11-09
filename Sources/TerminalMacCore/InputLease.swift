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
        let fd = try openValidatedLock(directory)
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            close(fd)
            guard isContention(code) else { throw Failure("Cannot acquire input lease: \(String(cString: strerror(code)))") }
            throw LeaseConflict(owner: readMetadata(directory)?.owner)
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

    /// A probe is not custody: it only establishes the instant's lock state.
    /// In particular, unreadable holder metadata never becomes an owner named "unknown".
    public enum Probe: Equatable {
        case free
        case held(owner: String, generation: Int)
        case heldUnknown
    }

    private static func isContention(_ code: Int32) -> Bool {
        code == EWOULDBLOCK || code == EAGAIN
    }

    /// Shared lock validation for both acquisition and probing. O_NONBLOCK prevents an
    /// unexpected FIFO from hanging before fstat can reject it. Never accept a linked,
    /// foreign-owned, or world/group-accessible lease file as the authority.
    private static func openValidatedLock(_ directory: URL) throws -> Int32 {
        let fd = open(directory.appendingPathComponent(lockName).path,
                      O_CREAT | O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure("Cannot open input lease lock: \(String(cString: strerror(errno)))") }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_nlink == 1, info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else {
            close(fd)
            throw Failure("Unsafe input lease lock; expected a private regular file with one link")
        }
        return fd
    }

    /// Free is returned ONLY after the validated file was exclusively flocked.
    /// Unexpected flock errors propagate. Metadata only names a genuine contention;
    /// it cannot make a held lock free or an unknown owner act as a credential.
    public static func probe(directory: URL) throws -> Probe {
        try probe(directory: directory) { flock($0, LOCK_EX | LOCK_NB) }
    }

    /// Injectable syscall seam for deterministic unusual flock errors in Core tests.
    static func probe(directory: URL, attemptLock: (Int32) -> Int32) throws -> Probe {
        let fd = try openValidatedLock(directory)
        defer { close(fd) }
        if attemptLock(fd) == 0 {
            guard flock(fd, LOCK_UN) == 0 else {
                throw Failure("Cannot release input lease probe: \(String(cString: strerror(errno)))")
            }
            return .free
        }
        let code = errno
        guard isContention(code) else {
            throw Failure("Cannot inspect input lease: \(String(cString: strerror(code)))")
        }
        guard let metadata = readMetadata(directory) else { return .heldUnknown }
        return .held(owner: metadata.owner, generation: metadata.generation)
    }

    /// A scenario's existing owner token is kept for cooperative CLI calls. This
    /// does not authenticate that token or hold the lease through the action.
    public enum Admission: Equatable { case allowed, locked(owner: String), lockedUnknown }
    public static func admission(probe: Probe, claimedOwner: String?) -> Admission {
        switch probe {
        case .free: return .allowed
        case .heldUnknown: return .lockedUnknown
        case .held(let owner, _):
            return claimedOwner == owner ? .allowed : .locked(owner: owner)
        }
    }

    /// Nil means native input is allowed, a non-nil explanation means denied.
    /// Probe errors must be handled as denial by the calling native-window gate.
    public static func nativeWindowDenial(probe: Probe, windowOwner: String?) -> String? {
        switch probe {
        case .free: return nil
        case .heldUnknown: return "another client (holder identity unavailable)"
        case .held(let owner, _): return windowOwner == owner ? nil : owner
        }
    }

    /// A holder's identity is diagnostic only, and a missing/unsafe metadata file
    /// must never block on a FIFO or authorize a guessed owner token.
    private static func readMetadata(_ directory: URL) -> Metadata? {
        let path = directory.appendingPathComponent(metadataName).path
        let input = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard input >= 0 else { return nil }
        defer { close(input) }
        var info = stat()
        guard fstat(input, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_nlink == 1, info.st_uid == geteuid(), info.st_mode & 0o077 == 0,
              info.st_size > 0, info.st_size <= 4096 else { return nil }
        var data = Data(count: Int(info.st_size))
        let count = data.withUnsafeMutableBytes { mutable in Darwin.read(input, mutable.baseAddress, Int(info.st_size)) }
        guard count == Int(info.st_size), let metadata = try? JSONDecoder().decode(Metadata.self, from: data),
              metadata.schema == schema,
              (try? validate(owner: metadata.owner)) != nil else { return nil }
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
