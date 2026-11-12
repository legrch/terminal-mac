import Foundation
import CryptoKit
import Darwin

/// Descriptor-relative storage used only by the native application service.
/// Shared inputs are data; no path below this API is used as a script/program.
public final class AppServiceDirectory {
    public let url: URL
    private let fd: Int32

    private init(url: URL, descriptor: Int32) { self.url = url; fd = descriptor }
    deinit { close(fd) }

    public static func open(_ url: URL, createLeaf: Bool = false, privateDirectory: Bool = false) throws -> AppServiceDirectory {
        let components = url.pathComponents
        guard url.isFileURL, components.first == "/", !components.contains("..") else { throw AppServiceContract.refuse("APP_SERVICE_UNSAFE_PATH") }
        var current = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard current >= 0 else { throw AppServiceContract.refuse("APP_SERVICE_IO") }
        do {
            for (index, name) in components.dropFirst().enumerated() {
                guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else { throw AppServiceContract.refuse("APP_SERVICE_UNSAFE_PATH") }
                if createLeaf && index == components.count - 2 {
                    if mkdirat(current, name, 0o700) != 0 && errno != EEXIST { throw AppServiceContract.refuse("APP_SERVICE_IO") }
                }
                let next = openat(current, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw AppServiceContract.refuse("APP_SERVICE_UNSAFE_PATH") }
                close(current); current = next
            }
            var info = stat()
            guard fstat(current, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
                  !privateDirectory || (info.st_uid == geteuid() && info.st_mode & 0o077 == 0) else {
                throw AppServiceContract.refuse("APP_SERVICE_UNSAFE_PATH")
            }
            return AppServiceDirectory(url: url, descriptor: current)
        } catch { close(current); throw error }
    }
    private func name(_ value: String) throws {
        guard AppServiceContract.path(value), !value.contains("/") else { throw AppServiceContract.refuse("APP_SERVICE_UNSAFE_PATH") }
    }
    /// Descriptor-relative, read-only existence check. ENOENT is the only
    /// accepted absence; symlinks/FIFOs/existing directories all collide.
    /// The exclusive mkdirat in install() remains the final race guard.
    public func requireAbsent(_ value: String) throws {
        try name(value)
        var info = stat()
        if fstatat(fd, value, &info, AT_SYMLINK_NOFOLLOW) == 0 {
            throw AppServiceContract.refuse("APP_SERVICE_INSTALLED_COLLISION")
        }
        guard errno == ENOENT else { throw AppServiceContract.refuse("APP_SERVICE_IO") }
    }
    public func child(_ value: String, create: Bool = false, exclusive: Bool = false) throws -> AppServiceDirectory {
        try name(value)
        if create {
            if mkdirat(fd, value, 0o700) != 0 {
                guard !exclusive && errno == EEXIST else { throw AppServiceContract.refuse("APP_SERVICE_UNRESOLVED") }
            }
            guard fsync(fd) == 0 else { throw AppServiceContract.refuse("APP_SERVICE_IO") }
        }
        let next = openat(fd, value, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard next >= 0 else { throw AppServiceContract.refuse("APP_SERVICE_UNSAFE_PATH") }
        return AppServiceDirectory(url: url.appendingPathComponent(value), descriptor: next)
    }
    /// Publish within the same descriptor-owned parent without overwriting any
    /// existing name. The temporary tree remains evidence on every failure.
    public func publishDirectory(from parent: AppServiceDirectory, named source: String, as destination: String) throws {
        try name(source); try name(destination)
        _ = try parent.child(source)
        if renameatx_np(parent.fd, source, fd, destination, UInt32(RENAME_EXCL)) != 0 {
            throw AppServiceContract.refuse(errno == EEXIST ? "APP_SERVICE_INSTALLED_COLLISION" : "APP_SERVICE_IO")
        }
        guard fsync(fd) == 0, fsync(parent.fd) == 0 else {
            throw AppServiceContract.refuse("APP_SERVICE_PUBLICATION_UNKNOWN")
        }
    }

    public func parent(of relative: String) throws -> (AppServiceDirectory, String) {
        guard AppServiceContract.path(relative) else { throw AppServiceContract.refuse("APP_SERVICE_UNSAFE_PATH") }
        var parts = relative.split(separator: "/").map(String.init)
        let leaf = parts.removeLast()
        var directory = self
        for part in parts { directory = try directory.child(part) }
        return (directory, leaf)
    }
    public func names(limit: Int = 128) throws -> [String] {
        let copy = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard copy >= 0, let directory = fdopendir(copy) else { if copy >= 0 { close(copy) }; throw AppServiceContract.refuse("APP_SERVICE_IO") }
        defer { closedir(directory) }
        var names: [String] = []
        errno = 0
        while let entry = readdir(directory) {
            let value = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
            }
            if value == "." || value == ".." { continue }
            guard names.count < limit else { throw AppServiceContract.refuse("APP_SERVICE_UNRESOLVED") }
            names.append(value)
            errno = 0
        }
        guard errno == 0 else { throw AppServiceContract.refuse("APP_SERVICE_IO") }
        return names.sorted()
    }
    private static func same(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_mode == b.st_mode &&
        a.st_nlink == b.st_nlink && a.st_size == b.st_size &&
        a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
        a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }
    public func read(_ value: String, limit: Int) throws -> Data? {
        try name(value)
        let input = openat(fd, value, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        if input < 0 && errno == ENOENT { return nil }
        guard input >= 0 else { throw AppServiceContract.refuse("APP_SERVICE_UNSAFE_PATH") }
        defer { close(input) }
        var before = stat()
        guard fstat(input, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG,
              before.st_nlink == 1, before.st_size >= 0, before.st_size <= limit else { throw AppServiceContract.refuse("APP_SERVICE_UNSAFE_PATH") }
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = Darwin.read(input, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw AppServiceContract.refuse("APP_SERVICE_IO") }
            if count == 0 { break }
            guard data.count + count <= limit else { throw AppServiceContract.refuse("APP_SERVICE_UNSAFE_PATH") }
            data.append(contentsOf: buffer.prefix(count))
        }
        var after = stat(), named = stat()
        guard fstat(input, &after) == 0, fstatat(fd, value, &named, AT_SYMLINK_NOFOLLOW) == 0,
              Self.same(before, after), Self.same(before, named), data.count == before.st_size else { throw AppServiceContract.refuse("APP_SERVICE_UNSAFE_PATH") }
        return data
    }
    /// Durable publication; failures preserve the partial/private evidence.
    /// The caller freezes its service on any uncertain publication result.
    public func write(_ data: Data, named value: String, createOnly: Bool = false) throws {
        try name(value)
        guard data.count <= 4 * 1024 * 1024 else { throw AppServiceContract.refuse("APP_SERVICE_INVALID") }
        let temporary = "pending-" + UUID().uuidString.lowercased() + ".json"
        let output = openat(fd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw AppServiceContract.refuse("APP_SERVICE_IO") }
        defer { close(output) }
        try Self.writeAll(output, data)
        guard fsync(output) == 0 else { throw AppServiceContract.refuse("APP_SERVICE_PUBLICATION_UNKNOWN") }
        let result = createOnly ? renameatx_np(fd, temporary, fd, value, UInt32(RENAME_EXCL)) : renameat(fd, temporary, fd, value)
        guard result == 0, fsync(fd) == 0 else { throw AppServiceContract.refuse("APP_SERVICE_PUBLICATION_UNKNOWN") }
    }
    private static func writeAll(_ output: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(output, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw AppServiceContract.refuse("APP_SERVICE_IO") }
                offset += count
            }
        }
    }
    public func lock() throws -> AppServiceLock {
        let lock = openat(fd, "service.lock", O_RDWR | O_CREAT | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw AppServiceContract.refuse("APP_SERVICE_UNSAFE_PATH") }
        var info = stat()
        guard fstat(lock, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_nlink == 1, info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else {
            close(lock); throw AppServiceContract.refuse("APP_SERVICE_UNSAFE_PATH")
        }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            let failure = errno; close(lock)
            throw AppServiceContract.refuse((failure == EWOULDBLOCK || failure == EAGAIN) ? "APP_SERVICE_BUSY" : "APP_SERVICE_IO")
        }
        return AppServiceLock(lock)
    }
    public func mode(_ value: Int) throws {
        guard (0...0o777).contains(value), fchmod(fd, mode_t(value)) == 0, fsync(fd) == 0 else { throw AppServiceContract.refuse("APP_SERVICE_IO") }
    }
    public func symlink(_ target: String, named value: String) throws {
        try name(value)
        guard AppServiceContract.path(target), symlinkat(target, fd, value) == 0, fsync(fd) == 0 else { throw AppServiceContract.refuse("APP_SERVICE_UNSAFE_PATH") }
    }
    public func copyBlob(_ blob: String, into destination: AppServiceDirectory, named leaf: String,
                         bytes: Int, sha256: String, mode: Int, check: () throws -> Void) throws {
        try name(blob); try destination.name(leaf); try check()
        let input = openat(fd, blob, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard input >= 0 else { throw AppServiceContract.refuse("APP_SERVICE_UNSAFE_PATH") }
        defer { close(input) }
        var before = stat()
        guard fstat(input, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG,
              before.st_nlink == 1, before.st_size == bytes else { throw AppServiceContract.refuse("APP_SERVICE_DIGEST") }
        let output = openat(destination.fd, leaf, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw AppServiceContract.refuse("APP_SERVICE_IO") }
        defer { close(output) }
        var hasher = SHA256(); var total = 0; var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            try check()
            let count = Darwin.read(input, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw AppServiceContract.refuse("APP_SERVICE_IO") }
            if count == 0 { break }
            total += count
            guard total <= bytes else { throw AppServiceContract.refuse("APP_SERVICE_DIGEST") }
            let data = Data(buffer.prefix(count)); hasher.update(data: data)
            try Self.writeAll(output, data)
        }
        var after = stat(), named = stat()
        let computed = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard total == bytes, computed == sha256, fstat(input, &after) == 0,
              fstatat(fd, blob, &named, AT_SYMLINK_NOFOLLOW) == 0,
              Self.same(before, after), Self.same(before, named) else { throw AppServiceContract.refuse("APP_SERVICE_DIGEST") }
        try check()
        guard fchmod(output, mode_t(mode)) == 0, fsync(output) == 0, fsync(destination.fd) == 0 else { throw AppServiceContract.refuse("APP_SERVICE_IO") }
    }
    /// VZMultipleDirectoryShare has one writable mount but per-share server
    /// read-only enforcement. MNT_RDONLY alone cannot attest those shares.
    /// The host-owned sentinel is ordinary, mode 0600, and contains fixed data.
    /// Opening it without truncation/create/write must be denied by AppleVirtIOFS;
    /// The controller separately checks VZ readOnly on the live configuration.
    /// Missing/changed input, other filesystems and a writable descriptor fail closed.
    public func requireReadOnlyVolume() throws {
        var info = statfs()
        guard fstatfs(fd, &info) == 0 else { throw AppServiceContract.refuse("APP_SERVICE_UNSAFE_PATH") }
        if info.f_flags & UInt32(MNT_RDONLY) != 0 { return }
        let type = withUnsafePointer(to: &info.f_fstypename) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { String(cString: $0) }
        }
        guard type == "AppleVirtIOFS",
              try node(ArtifactShareDirectory.probeName).kind == "file",
              try node(ArtifactShareDirectory.probeName).mode == 0o600,
              try read(ArtifactShareDirectory.probeName, limit: 128) == ArtifactShareDirectory.probeBytes else {
            throw AppServiceContract.refuse("APP_SERVICE_UNSAFE_PATH")
        }
        let probe = openat(fd, ArtifactShareDirectory.probeName, O_WRONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        let error = errno
        if probe >= 0 { close(probe); throw AppServiceContract.refuse("APP_SERVICE_UNSAFE_PATH") }
        guard error == EROFS || error == EACCES else { throw AppServiceContract.refuse("APP_SERVICE_UNSAFE_PATH") }
    }
    public func verifyFile(_ value: String, bytes: Int, sha256: String, mode: Int, check: () throws -> Void) throws {
        try name(value)
        let input = openat(fd, value, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard input >= 0 else { throw AppServiceContract.refuse("APP_SERVICE_UNSAFE_PATH") }
        defer { close(input) }
        var before = stat()
        guard fstat(input, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG,
              before.st_nlink == 1, before.st_size == bytes, Int(before.st_mode & 0o7777) == mode else {
            throw AppServiceContract.refuse("APP_SERVICE_DIGEST")
        }
        var hash = SHA256(); var total = 0; var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            try check()
            let count = Darwin.read(input, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw AppServiceContract.refuse("APP_SERVICE_IO") }
            if count == 0 { break }
            total += count
            guard total <= bytes else { throw AppServiceContract.refuse("APP_SERVICE_DIGEST") }
            hash.update(data: Data(buffer.prefix(count)))
        }
        var after = stat(), named = stat()
        guard total == bytes, hash.finalize().map({ String(format: "%02x", $0) }).joined() == sha256,
              fstat(input, &after) == 0, fstatat(fd, value, &named, AT_SYMLINK_NOFOLLOW) == 0,
              Self.same(before, after), Self.same(before, named) else { throw AppServiceContract.refuse("APP_SERVICE_DIGEST") }
    }
    public func node(_ value: String) throws -> (kind: String, mode: Int, target: String) {
        try name(value)
        var info = stat()
        guard fstatat(fd, value, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw AppServiceContract.refuse("APP_SERVICE_IO") }
        switch info.st_mode & S_IFMT {
        case S_IFDIR: return ("directory", Int(info.st_mode & 0o7777), "")
        case S_IFREG:
            guard info.st_nlink == 1 else { throw AppServiceContract.refuse("APP_SERVICE_UNSAFE_PATH") }
            return ("file", Int(info.st_mode & 0o7777), "")
        case S_IFLNK:
            var bytes = [UInt8](repeating: 0, count: 1025)
            let count = readlinkat(fd, value, &bytes, bytes.count)
            guard count > 0, count < bytes.count, let target = String(bytes: bytes.prefix(count), encoding: .utf8) else { throw AppServiceContract.refuse("APP_SERVICE_UNSAFE_PATH") }
            return ("symlink", Int(info.st_mode & 0o7777), target)
        default: throw AppServiceContract.refuse("APP_SERVICE_UNSAFE_PATH")
        }
    }
    public static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

public final class AppServiceLock {
    private let fd: Int32
    fileprivate init(_ fd: Int32) { self.fd = fd }
    deinit { flock(fd, LOCK_UN); close(fd) }
}

public enum AppServiceFiles {
    /// Read-only preflight BEFORE creating a native guest service operation.
    /// A pre-existing Farol.app in /Applications is not ours to replace.
    public static func requireGuestApplicationsAvailable(_ payload: AppServicePayload) throws {
        try payload.validate()
        let applications = try AppServiceDirectory.open(
            URL(fileURLWithPath: AppServiceContract.installationRoot, isDirectory: true))
        try applications.requireAbsent(payload.appName)
    }

    /// A finite guest-only installation target. A host request cannot choose
    /// a different directory, overwrite an installed app, or invoke an
    /// installer/privilege helper. The descriptor walk refuses symlink parents.
    /// If the guest user cannot create in /Applications, the operation fails
    /// closed and retains its original private service/effect evidence.
    public static func installInGuestApplications(
        _ payload: AppServicePayload, from stage: AppServiceDirectory,
        check: () throws -> Void, verify: (URL) throws -> Void
    ) throws -> URL {
        try check()
        let applications = try AppServiceDirectory.open(
            URL(fileURLWithPath: AppServiceContract.installationRoot, isDirectory: true))
        try applications.requireAbsent(payload.appName)
        let temporaryName = ".terminal-mac-install-" + UUID().uuidString.lowercased()
        let temporary = try applications.child(temporaryName, create: true, exclusive: true)
        let staged = try install(payload, from: stage, into: temporary, check: check)
        try verifyInstalled(payload, in: AppServiceDirectory.open(staged), check: check)
        try verify(staged)
        try check()
        try applications.publishDirectory(from: temporary, named: payload.appName, as: payload.appName)
        return applications.url.appendingPathComponent(payload.appName)
    }

    public static func payload(in stage: AppServiceDirectory, expectedDigest: String) throws -> (AppServicePayload, Data) {
        guard let data = try stage.read("app-payload.json", limit: 4 * 1024 * 1024),
              AppServiceDirectory.digest(data) == expectedDigest,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == Set(["schema", "appName", "bundleID", "version", "artifactSHA256", "archiveSHA256", "entries"]),
              let entries = object["entries"] as? [[String: Any]],
              entries.allSatisfy({ Set($0.keys) == Set(["path", "kind", "mode", "bytes", "sha256", "blob", "target"]) }) else {
            throw AppServiceContract.refuse("APP_SERVICE_PAYLOAD_INVALID")
        }
        let payload = try JSONDecoder().decode(AppServicePayload.self, from: data)
        try payload.validate()
        return (payload, data)
    }
    /// Never extracts an archive or executes a staged file. Only the declared
    /// tree is reconstructed inside a newly created guest-private run directory.
    public static func install(_ payload: AppServicePayload, from stage: AppServiceDirectory,
                               into run: AppServiceDirectory, check: () throws -> Void) throws -> URL {
        try payload.validate(); try check()
        let app = try run.child(payload.appName, create: true, exclusive: true)
        let directories = payload.entries.filter { $0.kind == "directory" }.sorted {
            let left = $0.path.split(separator: "/").count, right = $1.path.split(separator: "/").count
            return left == right ? $0.path < $1.path : left < right
        }
        for entry in directories {
            try check(); let (parent, leaf) = try app.parent(of: entry.path)
            _ = try parent.child(leaf, create: true, exclusive: true)
        }
        for entry in payload.entries where entry.kind == "file" {
            let (parent, leaf) = try app.parent(of: entry.path)
            try stage.copyBlob(entry.blob, into: parent, named: leaf, bytes: entry.bytes,
                               sha256: entry.sha256, mode: entry.mode, check: check)
        }
        for entry in payload.entries where entry.kind == "symlink" {
            try check(); let (parent, leaf) = try app.parent(of: entry.path)
            try parent.symlink(entry.target, named: leaf)
        }
        // Restrictive directory modes are applied only after all children exist.
        for entry in directories.reversed() {
            let (parent, leaf) = try app.parent(of: entry.path)
            try parent.child(leaf).mode(entry.mode)
        }
        try app.mode(0o755)
        return app.url
    }
    public static func verifyInstalled(_ payload: AppServicePayload, in app: AppServiceDirectory, check: () throws -> Void) throws {
        try payload.validate()
        let expected = Set(payload.entries.map { $0.path })
        var actual = Set<String>()
        func walk(_ directory: AppServiceDirectory, prefix: String) throws {
            for name in try directory.names(limit: 25000) {
                try check()
                let path = prefix.isEmpty ? name : prefix + "/" + name
                guard expected.contains(path), actual.insert(path).inserted else { throw AppServiceContract.refuse("APP_SERVICE_DIGEST") }
                let node = try directory.node(name)
                if node.kind == "directory" { try walk(directory.child(name), prefix: path) }
            }
        }
        try walk(app, prefix: "")
        guard actual == expected else { throw AppServiceContract.refuse("APP_SERVICE_DIGEST") }
        for entry in payload.entries {
            try check(); let (parent, leaf) = try app.parent(of: entry.path)
            let node = try parent.node(leaf)
            guard node.kind == entry.kind else { throw AppServiceContract.refuse("APP_SERVICE_DIGEST") }
            if entry.kind == "file" {
                try parent.verifyFile(leaf, bytes: entry.bytes, sha256: entry.sha256, mode: entry.mode, check: check)
            } else if entry.kind == "directory" {
                guard node.mode == entry.mode else { throw AppServiceContract.refuse("APP_SERVICE_DIGEST") }
            } else {
                guard node.target == entry.target else { throw AppServiceContract.refuse("APP_SERVICE_DIGEST") }
            }
        }
    }
    /// Read-only startup/update gate. Nothing is deleted, adopted, or replayed.
    public static func hasUnresolved(in rootURL: URL) -> Bool {
        var info = stat()
        if lstat(rootURL.path, &info) != 0 { return errno != ENOENT }
        do {
            let root = try AppServiceDirectory.open(rootURL, privateDirectory: true)
            for name in try root.names(limit: 130) where name != "service.lock" {
                guard AppServiceContract.run(name) else { return true }
                let run = try root.child(name)
                guard let data = try run.read("state.json", limit: 65536) else { return true }
                let record = try JSONDecoder().decode(AppServiceRecord.self, from: data)
                try record.validate()
                guard record.runID == name, record.phase == "closed", record.pending == nil,
                      let receipt = try run.read("receipt-" + record.operationID + ".json", limit: 65536),
                      try JSONDecoder().decode(AppServiceRecord.self, from: receipt) == record else { return true }
            }
            return false
        } catch { return true }
    }
}
