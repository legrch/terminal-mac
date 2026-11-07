import Foundation
import Darwin

/// A per-machine read-only guest inbox, separate from the signed app resources.
public enum ArtifactShareDirectory {
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
        return machineDirectory.appendingPathComponent("artifacts")
    }
}
