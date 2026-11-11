import Foundation
import Darwin

/// A missing lock means never started. An inaccessible or invalid lock is unknown,
/// not evidence that the virtual machine is stopped.
public enum RuntimeLock {
    public static func isHeld(in directory: URL) throws -> Bool {
        let fd = open(directory.appendingPathComponent("runtime.lock").path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT { return false }
            throw Failure("Cannot inspect VM runtime lock; VM state is unknown")
        }
        defer { close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            guard flock(fd, LOCK_UN) == 0 else { throw Failure("Cannot release VM runtime lock; VM state is unknown") }
            return false
        }
        if errno == EWOULDBLOCK || errno == EAGAIN { return true }
        throw Failure("Cannot inspect VM runtime lock; VM state is unknown")
    }
}
