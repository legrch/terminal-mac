import Foundation
import Darwin

/// Host-side exclusive guest-input ownership for one machine.
///
/// The flock file is the cooperative live-owner authority. The kernel releases flock on a
/// crash, but persisted machine metadata or a helper-update marker remains an unresolved-effect
/// fence until reconciled: a free flock alone is NOT permission to acquire the lease.
/// The sibling JSON records owner/generation/time, but is not a transferable credential.
/// Consumers that cannot use this class — a product
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
    public static let operationName = "input-operation.json"
    static let closingName = "input-closing.json"
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
    // The exact file this acquisition created. Stale or substituted records are not ours
    // to remove, even if they carry the same owner text.
    struct MetadataReceipt: Equatable {
        let device: UInt64
        let inode: UInt64
        let bytes: Data
    }
    private let metadataReceipt: MetadataReceipt

    private init(directory: URL, fd: Int32, owner: String, generation: Int,
                 metadataReceipt: MetadataReceipt) {
        self.directory = directory
        self.fd = fd
        self.owner = owner
        self.generation = generation
        self.metadataReceipt = metadataReceipt
    }

    public static func validate(owner: String) throws {
        guard !owner.isEmpty, owner.utf8.count <= 128,
              owner.allSatisfy({ c in c.isASCII && (c.isLetter || c.isNumber || "-_.:".contains(c)) }) else {
            throw Failure("Lease owner must be 1-128 letters, numbers, hyphens, dots, underscores or colons")
        }
    }

    /// Acquisition checks BOTH predecessor records while owning the kernel flock. Neither an
    /// expired/unreadable update marker nor an orphaned machine metadata file authorizes takeover.
    /// A failed/uncertain publication leaves its new metadata for explicit reconciliation.
    public static func acquire(directory: URL, owner: String, generation: Int) throws -> InputLease {
        try acquire(directory: directory, owner: owner, generation: generation,
                    beforeMetadataPublication: {}, beforeDirectorySync: {})
    }

    /// Deterministic fault/race seams for Core tests. Production uses the public wrapper above.
    /// These closures execute while the real kernel flock is held; they never run in the guest.
    static func acquire(directory: URL, owner: String, generation: Int,
                        beforeMetadataPublication: () throws -> Void,
                        beforeDirectorySync: () throws -> Void) throws -> InputLease {
        try validate(owner: owner)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let fd = try openValidatedLock(directory)
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            close(fd)
            guard isContention(code) else {
                throw Failure("Cannot acquire input lease: \(String(cString: strerror(code)))")
            }
            throw LeaseConflict(owner: readMetadata(directory)?.owner)
        }
        do {
            // Do not use fileExists: a dangling symlink can appear absent. An unclassifiable
            // lstat error also refuses; only ENOENT proves there is no predecessor metadata.
            try requireNoOperationFence(directory)
            guard try !hasClosingFence(directory) else { throw Failure("Input holder teardown remains unresolved") }
            try requireNoOutstandingMetadata(directory)
            let exchange = try Mailbox(directory.appendingPathComponent("exchange"), create: true)
            try exchange.requireNoOutstandingUpdateMarker()
            let metadata = Metadata(schema: schema, owner: owner, generation: generation,
                                    acquiredAt: Int(Date().timeIntervalSince1970))
            let bytes = try JSONEncoder().encode(metadata)
            try beforeMetadataPublication()
            // O_EXCL is the second admission barrier if an uncooperative writer creates a
            // record after the lstat preflight. Never rename over any predecessor entry.
            let receipt = try publishExclusiveMetadata(bytes, directory: directory,
                                                       beforeDirectorySync: beforeDirectorySync)
            return InputLease(directory: directory, fd: fd, owner: owner,
                              generation: generation, metadataReceipt: receipt)
        } catch {
            // Only the kernel lock is ours to release on prepublication failure. Never
            // unlink a possibly preexisting or ambiguously published metadata/marker file.
            _ = flock(fd, LOCK_UN)
            close(fd)
            throw error
        }
    }

    /// A clean release removes only this acquisition's exact metadata inode and bytes.
    /// An unresolved action, lost marker-release ACK or abnormal exit retains the record;
    /// releasing flock alone never proves an issued guest effect finished.
    public func release(preserveMetadata: Bool = false, relocatedDirectory: URL? = nil) {
        guard !released else { return }
        released = true
        // A borrowed native/CLI operation may still be in flight after its
        // original holder exits. Its durable fence owns both custody records.
        let location = relocatedDirectory ?? directory
        if !preserveMetadata || (try? Self.hasClosingFence(location)) == true {
            try? Self.withAdmission(directory: location, wait: true) {
                guard try !Self.hasOperationFence(location) else { return }
                let closing = try Self.closingMatches(directory: location, owner: owner)
                guard !preserveMetadata || closing else { return }
                if closing {
                    let box = try Mailbox(location.appendingPathComponent("exchange"))
                    try box.releaseLeaseFlagUnderAdmission(ownedBy: owner)
                }
                guard Self.removeOwnedMetadata(directory: location, receipt: metadataReceipt) else { return }
                if closing { try Self.removeClosing(directory: location) }
            }
        }
        _ = flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }

    deinit {
        if !released && fd >= 0 { flock(fd, LOCK_UN); close(fd) }
    }

    /// A probe is not custody: it only establishes the instant's admission state.
    /// A free kernel lock plus orphaned metadata/update marker is UNRESOLVED, not FREE;
    /// in particular, an unavailable holder never becomes an owner named "unknown".
    public enum Probe: Equatable {
        case free
        case held(owner: String, generation: Int)
        case heldUnknown
        case unresolved
    }

    /// Short cross-process admission barrier shared by operation publication,
    /// marker teardown and metadata release. Never wait behind another client.
    static func withAdmission<T>(directory: URL, wait: Bool = false, _ body: () throws -> T) throws -> T {
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Failure("Cannot open input admission directory") }
        defer { close(fd) }
        return try withAdmission(directoryFD: fd, name: "input-admission.lock", wait: wait, body)
    }
    static func withAdmission<T>(directoryFD: Int32, name: String, wait: Bool = false, _ body: () throws -> T) throws -> T {
        let lock = openat(directoryFD, name, O_CREAT | O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw Failure("Cannot open input admission lock") }
        defer { close(lock) }
        var info = stat()
        guard fstat(lock, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_nlink == 1, info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else {
            throw Failure("Unsafe input admission lock")
        }
        guard flock(lock, wait ? LOCK_EX : LOCK_EX | LOCK_NB) == 0 else { throw Failure("Guest input custody is changing; dispatch refused") }
        defer { _ = flock(lock, LOCK_UN) }
        return try body()
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

    /// Free requires a validated, successfully flocked file AND absence of both
    /// predecessor evidence entries while the flock is held. Unexpected I/O errors
    /// propagate. A stale record is not an owner credential or proof of completion.
    public static func probe(directory: URL) throws -> Probe {
        try probe(directory: directory) { flock($0, LOCK_EX | LOCK_NB) }
    }

    /// Injectable syscall seam for deterministic unusual flock errors in Core tests.
    static func probe(directory: URL, attemptLock: (Int32) -> Int32) throws -> Probe {
        if try hasOperationFence(directory) || hasClosingFence(directory) { return .unresolved }
        let fd = try openValidatedLock(directory)
        defer { close(fd) }
        if attemptLock(fd) == 0 {
            // Inspect under the same nonblocking flock. The exception path still unlocks;
            // retained evidence is never removed by an observational probe.
            let state: Probe
            do { state = try predecessorProbe(directory) }
            catch {
                _ = flock(fd, LOCK_UN)
                throw error
            }
            guard flock(fd, LOCK_UN) == 0 else {
                throw Failure("Cannot release input lease probe: \(String(cString: strerror(errno)))")
            }
            return state
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
    public enum Admission: Equatable { case allowed, locked(owner: String), lockedUnknown, lockedUnresolved }
    public static func admission(probe: Probe, claimedOwner: String?) -> Admission {
        switch probe {
        case .free: return .allowed
        case .heldUnknown: return .lockedUnknown
        case .unresolved: return .lockedUnresolved
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
        case .unresolved: return "an unresolved previous guest operation (input refused)"
        case .held(let owner, _): return windowOwner == owner ? nil : owner
        }
    }

    /// A holder's identity is diagnostic only, and a missing/unsafe metadata file
    /// must never block on a FIFO or authorize a guessed owner token.
    private static func readMetadata(_ directory: URL) -> Metadata? { readMetadataRecord(directory)?.0 }
    private static func readMetadataRecord(_ directory: URL) -> (Metadata, MetadataReceipt)? {
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
        return (metadata, MetadataReceipt(device: UInt64(info.st_dev), inode: UInt64(info.st_ino), bytes: data))
    }

    static func borrowedMetadataReceipt(directory: URL, owner: String, generation: Int) throws -> MetadataReceipt {
        guard let (metadata, receipt) = readMetadataRecord(directory), metadata.owner == owner,
              metadata.generation == generation else { throw Failure("Cooperative holder metadata changed") }
        return receipt
    }

    /// Called under admission. A live holder drains a closing request on release;
    /// an exited holder is reconciled under its original, now-free kernel lock.
    static func finishBorrowed(directory: URL, receipt: MetadataReceipt,
                               confirmed: (Bool) throws -> Void) throws {
        let lock = try openValidatedLock(directory)
        defer { close(lock) }
        let orphaned = flock(lock, LOCK_EX | LOCK_NB) == 0
        if !orphaned && !isContention(errno) { throw Failure("Cannot reconcile cooperative completion") }
        defer { if orphaned { _ = flock(lock, LOCK_UN) } }
        guard let (_, actual) = readMetadataRecord(directory), actual == receipt else {
            throw Failure("Cooperative custody record changed; preserve operation evidence")
        }
        try confirmed(orphaned)
        if orphaned {
            guard removeOwnedMetadata(directory: directory, receipt: receipt) else {
                throw Failure("Cannot durably release confirmed orphan custody")
            }
            if try hasClosingFence(directory) { try removeClosing(directory: directory) }
        }
    }

    /// Read-only predecessor admission after the probe acquired the kernel lock.
    /// A missing exchange directory is the ordinary pre-bootstrap state; every
    /// present unsafe exchange or update marker refuses instead of guessing FREE.
    /// The mailbox opens its directory with O_DIRECTORY|O_NOFOLLOW, and its marker
    /// reader uses O_NONBLOCK, so dangling symlinks and FIFOs cannot hang a probe.
    private static func predecessorProbe(_ directory: URL) throws -> Probe {
        if try hasOperationFence(directory) || hasClosingFence(directory) { return .unresolved }
        var info = stat()
        let metadata = directory.appendingPathComponent(metadataName).path
        if lstat(metadata, &info) == 0 { return .unresolved }
        guard errno == ENOENT else {
            throw Failure("Cannot inspect input lease predecessor metadata: \(String(cString: strerror(errno)))")
        }
        let exchangeURL = directory.appendingPathComponent("exchange")
        if lstat(exchangeURL.path, &info) != 0 {
            guard errno == ENOENT else {
                throw Failure("Cannot inspect guest exchange for custody evidence: \(String(cString: strerror(errno)))")
            }
            return .free
        }
        // An exchange alias, FIFO, or other unexpected entry is not an absent
        // marker. Do not follow or open it to search for a potentially stale flag.
        guard (info.st_mode & S_IFMT) == S_IFDIR else { return .unresolved }
        let mailbox = try Mailbox(exchangeURL)
        return mailbox.helperUpdateDisposition() == .unmarked ? .free : .unresolved
    }

    static func borrowedHolderMatches(directory: URL, owner: String, generation: Int) throws -> Bool {
        let fd = try openValidatedLock(directory)
        defer { close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            _ = flock(fd, LOCK_UN)
            return false
        }
        guard isContention(errno) else { throw Failure("Cannot verify borrowed input custody") }
        guard let metadata = readMetadata(directory) else { return false }
        return metadata.owner == owner && metadata.generation == generation
    }

    static func hasOperationFence(_ directory: URL) throws -> Bool { try hasEvidence(directory, name: operationName) }
    static func hasClosingFence(_ directory: URL) throws -> Bool { try hasEvidence(directory, name: closingName) }
    private static func hasEvidence(_ directory: URL, name: String) throws -> Bool {
        var info = stat()
        if lstat(directory.appendingPathComponent(name).path, &info) == 0 { return true }
        guard errno == ENOENT else { throw Failure("Cannot inspect guest operation fence") }
        return false
    }
    private static func requireNoOperationFence(_ directory: URL) throws {
        guard try !hasOperationFence(directory) else {
            throw Failure("Previous guest input operation is unresolved; reconcile retained operation evidence")
        }
    }

    private static func requireNoOutstandingMetadata(_ directory: URL) throws {
        var info = stat()
        let path = directory.appendingPathComponent(metadataName).path
        if lstat(path, &info) == 0 {
            throw Failure("Unresolved input lease metadata exists; reconcile the previous owner before acquiring guest input")
        }
        guard errno == ENOENT else {
            throw Failure("Cannot inspect input lease predecessor metadata: \(String(cString: strerror(errno)))")
        }
    }

    /// Create only a previously absent owner record, never replace via rename. A partial write,
    /// failed sync or crash may leave an incomplete file, which blocks the next acquisition until
    /// explicit reconciliation. In particular, a successful kernel lock does not clear it.
    private static func publishExclusiveMetadata(_ data: Data, directory: URL,
                                                 beforeDirectorySync: () throws -> Void) throws -> MetadataReceipt {
        let path = directory.appendingPathComponent(metadataName).path
        let out = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard out >= 0 else {
            if errno == EEXIST {
                throw Failure("Unresolved input lease metadata appeared during acquisition; refuse overwrite")
            }
            throw Failure("Cannot publish exclusive input lease metadata: \(String(cString: strerror(errno)))")
        }
        var info = stat()
        do {
            guard fstat(out, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
                  info.st_nlink == 1, info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else {
                throw Failure("Cannot verify exclusive input lease metadata file")
            }
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.write(out, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw Failure("Cannot write input lease metadata") }
                    offset += count
                }
            }
            guard fsync(out) == 0 else { throw Failure("Cannot sync input lease metadata") }
        } catch {
            // The newly created file may be visible/partly durable: preserve, never unlink.
            close(out)
            throw error
        }
        guard close(out) == 0 else { throw Failure("Cannot close input lease metadata safely") }
        try beforeDirectorySync()
        try syncDirectoryChecked(directory)
        return MetadataReceipt(device: UInt64(info.st_dev), inode: UInt64(info.st_ino), bytes: data)
    }

    @discardableResult
    private static func removeOwnedMetadata(directory: URL, receipt: MetadataReceipt) -> Bool {
        let path = directory.appendingPathComponent(metadataName).path
        let input = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard input >= 0 else { return false }
        defer { close(input) }
        var info = stat()
        guard fstat(input, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_nlink == 1, info.st_uid == geteuid(), info.st_mode & 0o077 == 0,
              UInt64(info.st_dev) == receipt.device,
              UInt64(info.st_ino) == receipt.inode, info.st_size == receipt.bytes.count else { return false }
        var bytes = Data(count: receipt.bytes.count)
        let count = bytes.withUnsafeMutableBytes { pointer -> Int in
            guard let base = pointer.baseAddress else { return 0 }
            var offset = 0
            while offset < pointer.count {
                let n = Darwin.read(input, base.advanced(by: offset), pointer.count - offset)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { return -1 }
                offset += n
            }
            return offset
        }
        guard count == receipt.bytes.count, bytes == receipt.bytes else { return false }
        // Protect against a swapped pathname after opening the descriptor. The kernel flock
        // serializes cooperative owners; this is not an adversarial filesystem transaction.
        var named = stat()
        guard lstat(path, &named) == 0, UInt64(named.st_dev) == receipt.device,
              UInt64(named.st_ino) == receipt.inode else { return false }
        guard unlink(path) == 0 else { return false }
        return (try? syncDirectoryChecked(directory)) != nil
    }

    /// Closing intent is durable before the holder can abandon its kernel lock.
    static func publishClosing(directoryFD: Int32, owner: String) throws {
        try validate(owner: owner)
        let out = openat(directoryFD, closingName, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard out >= 0 else { throw Failure("Cannot publish input closing intent; preserve custody") }
        defer { close(out) }
        let data = Data(owner.utf8)
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(out, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw Failure("Cannot write input closing intent") }
                offset += count
            }
        }
        guard fsync(out) == 0, fsync(directoryFD) == 0 else { throw Failure("Input closing intent durability is unconfirmed") }
    }
    static func closingMatches(directory: URL, owner: String) throws -> Bool {
        guard let data = try Mailbox(directory).read(closingName, limit: 128) else { return false }
        guard data == Data(owner.utf8) else { throw Failure("Input closing owner changed; preserve custody") }
        return true
    }
    private static func removeClosing(directory: URL) throws {
        guard unlink(directory.appendingPathComponent(closingName).path) == 0 else {
            throw Failure("Cannot release input closing intent")
        }
        try syncDirectoryChecked(directory)
    }

    private static func syncDirectoryChecked(_ directory: URL) throws {
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            throw Failure("Cannot open input lease metadata directory for sync")
        }
        let result = fsync(fd)
        let code = errno
        close(fd)
        guard result == 0 else { throw Failure("Cannot sync input lease metadata directory: \(String(cString: strerror(code)))") }
    }

    static func syncDirectory(_ directory: URL) {
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return }
        _ = fsync(fd)
        close(fd)
    }
}
