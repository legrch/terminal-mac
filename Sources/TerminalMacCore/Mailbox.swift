import Foundation
import Darwin

/// A request nobody answered in time. `pickedUp` is false when the request file was still
/// visible to the caller, which usually means no helper is running — but visibility through the
/// exchange is diagnostic only: it is not proof that no effect occurred, so timeouts never clear
/// dependent input.
public struct MailboxTimeout: LocalizedError {
    public let action: String
    public let pickedUp: Bool
    public var errorDescription: String? {
        "Timed out waiting for \(action). Ensure the VM is running and the guest helper is open in its logged-in desktop."
    }
}

/// Flat virtio-fs mailbox. No network listener, credentials, or executable guest responses.
/// Pin the directory and reject symlinks for every exchanged file.
///
/// Publication is caller-owned. `call` creates an empty reply slot before posting the request and
/// `respond` writes into that existing slot; once the caller stops waiting it removes the slot, so
/// a late responder cannot recreate a named reply after the caller gave up or was cancelled. Screenshot
/// artifacts follow the same rule: the caller prepares an `image-` slot and the helper publishes
/// into it. These slot guarantees require both peers to implement this protocol. A legacy peer can
/// still recreate a late reply; compatible peer admission is not yet enforced here.
public final class Mailbox {
    private let fd: Int32
    public init(_ url: URL, create: Bool = false) throws {
        if create { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Failure("Cannot open mailbox \(url.path): \(String(cString: strerror(errno)))") }
    }
    deinit { close(fd) }
    private func check(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else { throw Failure("Invalid mailbox filename") }
    }
    public func write(_ data: Data, named name: String) throws {
        try write(data, named: name, replacing: true)
    }
    private func write(_ data: Data, named name: String, replacing: Bool) throws {
        try check(name)
        let temporary = ".\(UUID().uuidString).tmp"
        let out = openat(fd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard out >= 0 else { throw Failure("Cannot create mailbox file: \(String(cString: strerror(errno)))") }
        defer { close(out); unlinkat(fd, temporary, 0) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(out, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw Failure("Cannot write mailbox file") }
                offset += count
            }
        }
        let result = replacing ? renameat(fd, temporary, fd, name) :
            renameatx_np(fd, temporary, fd, name, UInt32(RENAME_EXCL))
        guard result == 0 else {
            if !replacing && errno == EEXIST { throw Failure("Stale mailbox request '\(name)' already exists") }
            throw Failure("Cannot publish mailbox file: \(String(cString: strerror(errno)))")
        }
    }
    /// Create an empty caller-owned publication slot. Never overwrites existing content.
    public func prepareSlot(_ name: String) throws {
        try check(name)
        let out = openat(fd, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard out >= 0 else {
            if errno == EEXIST { throw Failure("Stale mailbox slot '\(name)' already exists") }
            throw Failure("Cannot prepare mailbox slot: \(String(cString: strerror(errno)))")
        }
        close(out)
    }
    /// Write into an existing caller-owned slot. A revoked (removed) slot refuses publication
    /// instead of recreating the name, so no late write can resurrect a file after cleanup.
    public func publish(_ data: Data, into name: String) throws {
        try check(name)
        let out = openat(fd, name, O_WRONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard out >= 0 else {
            if errno == ENOENT { throw Failure("Mailbox slot '\(name)' was revoked; nothing published") }
            throw Failure("Cannot publish mailbox file (symlinks are rejected): \(String(cString: strerror(errno)))")
        }
        defer { close(out) }
        // Check the opened object before truncating; O_NONBLOCK also avoids hanging on a FIFO.
        var info = stat()
        guard fstat(out, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1 else {
            throw Failure("Invalid mailbox publication slot")
        }
        guard ftruncate(out, 0) == 0 else { throw Failure("Cannot truncate mailbox publication slot") }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(out, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw Failure("Cannot write mailbox file") }
                offset += count
            }
        }
    }
    public func read(_ name: String, limit: Int = 1_048_576) throws -> Data? {
        try check(name)
        let input = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if input < 0 && errno == ENOENT { return nil }
        guard input >= 0 else { throw Failure("Cannot read mailbox file (symlinks are rejected)") }
        defer { close(input) }
        var info = stat()
        guard fstat(input, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1,
              info.st_size >= 0, info.st_size <= limit else { throw Failure("Invalid or oversized mailbox file") }
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = Darwin.read(input, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw Failure("Mailbox read failed") }
            if count == 0 { break }
            guard data.count + count <= limit else { throw Failure("Mailbox file exceeded size limit") }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
    public func remove(_ name: String) { if (try? check(name)) != nil { unlinkat(fd, name, 0) } }
    /// Exchange residue from callers that died before their deferred cleanup outlives any legal
    /// request deadline; legal deadlines are far below this bound, so live slots are never swept.
    static let residueAge: TimeInterval = 300
    /// Remove one reply or image entry if it is stale, regular-file residue. Links are unlinked
    /// without being followed.
    private func sweepStale(named name: String) {
        var info = stat()
        guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return }
        let modified = Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000)
        guard Date().timeIntervalSince(modified) > Self.residueAge else { return }
        unlinkat(fd, name, 0)
    }
    public func requests() throws -> [Request] {
        // Open a fresh description: dup() would share the directory iteration offset.
        let copy = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard copy >= 0, let directory = fdopendir(copy) else { if copy >= 0 { close(copy) }; throw Failure("Cannot list mailbox") }
        defer { closedir(directory) }
        var requests: [Request] = []
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
            }
            if name.hasPrefix("reply-") || name.hasPrefix("image-") { sweepStale(named: name); continue }
            guard name.hasPrefix("request-"), name.hasSuffix(".json") else { continue }
            defer { remove(name) }
            guard let data = try? read(name, limit: 262144), let request = try? JSONDecoder().decode(Request.self, from: data),
                  name == "request-\(request.id.uuidString).json", request.deadline > Date() else { continue }
            requests.append(request)
            if requests.count == 32 { break }
        }
        return requests.sorted { $0.deadline < $1.deadline }
    }
    public func respond(_ reply: Reply) throws { try publish(JSONEncoder().encode(reply), into: "reply-\(reply.id.uuidString).json") }

    /// Guest-input lease flag written into the exchange by the lease holder. The guest helper
    /// reads it to defer self-replacement while a scenario owns input; the flock lease remains
    /// the host-side authority. An unreadable or expired flag fences nothing.
    public struct LeaseFlag: Codable, Equatable {
        public let schema: String
        public let owner: String
        public let deadline: Double
    }
    public static let leaseFlagName = ".input-lease.json"
    public static let leaseFlagSchema = "terminal-mac.input-lease-flag/1"
    public func publishLeaseFlag(owner: String, ttl: TimeInterval, now: Date = Date()) throws {
        try write(JSONEncoder().encode(LeaseFlag(schema: Self.leaseFlagSchema, owner: owner,
                                                 deadline: now.addingTimeInterval(ttl).timeIntervalSince1970)),
                  named: Self.leaseFlagName)
    }
    public func leaseFlagHolder(now: Date = Date()) -> String? {
        guard let data = try? read(Self.leaseFlagName, limit: 4096),
              let flag = try? JSONDecoder().decode(LeaseFlag.self, from: data),
              flag.schema == Self.leaseFlagSchema, flag.deadline > now.timeIntervalSince1970 else { return nil }
        return flag.owner
    }
    public func clearLeaseFlag() { remove(Self.leaseFlagName) }
    public func call(_ request: Request) async throws -> Reply {
        try request.requireLive()
        let requestName = "request-\(request.id.uuidString).json"
        let replyName = "reply-\(request.id.uuidString).json"
        try prepareSlot(replyName)
        defer { remove(replyName) }
        // Refuse a preexisting request, and clean this request only after publication succeeds.
        try write(JSONEncoder().encode(request), named: requestName, replacing: false)
        defer { remove(requestName) }
        // Most replies land within a few milliseconds; back off for slow actions.
        var interval: UInt64 = 2_000_000
        while Date() < request.deadline {
            try Task.checkCancellation()
            // The slot is written in place, so intermediate bytes can be observed; wait for the
            // complete reply instead of failing on a partial payload.
            if let data = try read(replyName), let reply = try? JSONDecoder().decode(Reply.self, from: data) {
                guard reply.id == request.id else { throw Failure("Mismatched reply") }
                if !reply.ok { throw OutcomeFailure(reply.error ?? "Action failed", outcome: reply.outcome ?? .mutationUnknown) }
                return reply
            }
            try await Task.sleep(nanoseconds: interval)
            interval = min(25_000_000, interval * 3 / 2)
        }
        throw MailboxTimeout(action: request.action, pickedUp: (try? read(requestName)) == nil)
    }
}
