import Foundation
import Darwin

/// A request nobody answered in time. `pickedUp` is false when the request file was never even
/// read: no helper is running, for example because the guest is still at its login screen.
public struct MailboxTimeout: LocalizedError {
    public let action: String
    public let pickedUp: Bool
    public var errorDescription: String? {
        "Timed out waiting for \(action). Ensure the VM is running and the guest helper is open in its logged-in desktop."
    }
}

/// Flat virtio-fs mailbox. No network listener, credentials, or executable guest responses.
/// Pin the directory and reject symlinks for every exchanged file.
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
        guard renameat(fd, temporary, fd, name) == 0 else { throw Failure("Cannot publish mailbox file") }
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
            guard name.hasPrefix("request-"), name.hasSuffix(".json") else { continue }
            defer { remove(name) }
            guard let data = try? read(name, limit: 262144), let request = try? JSONDecoder().decode(Request.self, from: data),
                  name == "request-\(request.id.uuidString).json", request.deadline > Date() else { continue }
            requests.append(request)
            if requests.count == 32 { break }
        }
        return requests.sorted { $0.deadline < $1.deadline }
    }
    public func respond(_ reply: Reply) throws { try write(JSONEncoder().encode(reply), named: "reply-\(reply.id.uuidString).json") }
    public func call(_ request: Request) async throws -> Reply {
        try request.requireLive()
        let requestName = "request-\(request.id.uuidString).json"
        let replyName = "reply-\(request.id.uuidString).json"
        defer { remove(requestName); remove(replyName) }
        try write(JSONEncoder().encode(request), named: requestName)
        // Most replies land within a few milliseconds; back off for slow actions.
        var interval: UInt64 = 2_000_000
        while Date() < request.deadline {
            try Task.checkCancellation()
            if let data = try read(replyName) {
                let reply = try JSONDecoder().decode(Reply.self, from: data)
                guard reply.id == request.id else { throw Failure("Mismatched reply") }
                if !reply.ok { throw Failure(reply.error ?? "Action failed") }
                return reply
            }
            try await Task.sleep(nanoseconds: interval)
            interval = min(25_000_000, interval * 3 / 2)
        }
        throw MailboxTimeout(action: request.action, pickedUp: (try? read(requestName)) == nil)
    }
}
