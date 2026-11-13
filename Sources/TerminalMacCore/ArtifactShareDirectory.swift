import Foundation
import Darwin

/// A per-machine read-only guest inbox, separate from the signed app resources.
public enum ArtifactShareDirectory {
    public static let probeName = ".terminal-mac-readonly-probe"
    public static let probeBytes = Data("terminal-mac.artifact-share-probe/1\n".utf8)
    public static func prepare(in machineDirectory: URL) throws -> URL {
        let parent = open(machineDirectory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw Failure("Cannot open VM directory for artifact share") }
        defer { close(parent) }
        if mkdirat(parent, "artifacts", 0o700) != 0 && errno != EEXIST {
            throw Failure("Cannot create VM artifact share")
        }
        let child = openat(parent, "artifacts", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard child >= 0 else { throw Failure("VM artifact share must be a real directory") }
        defer { close(child) }
        var info = stat()
        guard fstat(child, &info) == 0, info.st_uid == getuid(), (info.st_mode & 0o077) == 0 else {
            throw Failure("VM artifact share must be private and owned by the current user")
        }
        let sentinel = openat(child, probeName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        if sentinel >= 0 {
            defer { close(sentinel) }
            let count = probeBytes.withUnsafeBytes { Darwin.write(sentinel, $0.baseAddress!, $0.count) }
            guard count == probeBytes.count, fsync(sentinel) == 0, fsync(child) == 0 else {
                throw Failure("Cannot publish artifact read-only probe")
            }
        } else if errno != EEXIST { throw Failure("Cannot prepare artifact read-only probe") }
        let root = try AppServiceDirectory.open(machineDirectory.appendingPathComponent("artifacts"), privateDirectory: true)
        let node = try root.node(probeName)
        guard node.kind == "file", node.mode == 0o600,
              try root.read(probeName, limit: 128) == probeBytes else {
            throw Failure("Artifact read-only probe changed")
        }
        return machineDirectory.appendingPathComponent("artifacts")
    }
}
