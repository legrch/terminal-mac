import Darwin
import Foundation

/// One dispatch under an acquired lease, or an explicitly cooperating live holder.
/// The exclusive operation record serializes borrowed-owner calls too. It contains
/// no input text and remains a replay fence on every unknown outcome.
public final class GuestInputCustody {
    private let lease: InputLease?
    private let mailbox: Mailbox
    private let directory: Int32
    private let owner: String
    private let location: URL
    private let borrowedReceipt: InputLease.MetadataReceipt?
    private var completed = false
    private struct FenceReceipt {
        let device: UInt64
        let inode: UInt64
        let bytes: Data
    }
    private var fenceReceipt: FenceReceipt?

    public static func begin(directory: URL, mailbox: Mailbox, request: Request,
                             claimedOwner: String? = nil) throws -> GuestInputCustody {
        try begin(directory: directory, mailbox: mailbox, request: request, claimedOwner: claimedOwner, afterProbe: {})
    }
    static func begin(directory: URL, mailbox: Mailbox, request: Request,
                      claimedOwner: String?, afterProbe: () throws -> Void) throws -> GuestInputCustody {
        try InputLease.withAdmission(directory: directory) {
            try beginUnderAdmission(directory: directory, mailbox: mailbox, request: request,
                                    claimedOwner: claimedOwner, afterProbe: afterProbe)
        }
    }
    private static func beginUnderAdmission(directory: URL, mailbox: Mailbox, request: Request,
                                            claimedOwner: String?, afterProbe: () throws -> Void) throws -> GuestInputCustody {
        try request.requireLive()
        let state = try InputLease.probe(directory: directory)
        try afterProbe()
        let lease: InputLease?
        let owner: String
        let generation: Int
        switch state {
        case .free:
            owner = claimedOwner ?? "cli:" + UUID().uuidString.lowercased()
            generation = Int(Date().timeIntervalSince1970)
            // This acquisition repeats predecessor admission under flock. A free probe
            // never authorizes dispatch if another holder wins the intervening race.
            lease = try InputLease.acquire(directory: directory, owner: owner,
                generation: generation)
        case .held(let holder, let heldGeneration) where claimedOwner == holder:
            owner = holder; generation = heldGeneration; lease = nil
        case .held(let holder, _): throw LeaseConflict(owner: holder)
        case .heldUnknown: throw LeaseConflict(owner: nil)
        case .unresolved: throw Failure("Previous guest input operation is unresolved; reconcile retained custody evidence")
        }
        do {
            if lease == nil {
                // Marker absence means holder teardown has already started.
                // Borrowers never recreate its inhibitor or reopen admission.
                switch mailbox.helperUpdateDisposition() {
                case .active(let current) where current == owner, .stale(let current) where current == owner: break
                default: throw Failure("Cooperative holder has no active helper-update custody")
                }
            }
            let custody = try GuestInputCustody(directory: directory, mailbox: mailbox,
                request: request, owner: owner, generation: generation, lease: lease)
            if lease == nil {
                guard try InputLease.borrowedHolderMatches(directory: directory, owner: owner, generation: generation) else {
                    throw Failure("The cooperative input holder changed before dispatch; preserve operation evidence")
                }
            }
            // Admission and teardown use one lock. Borrowers require the
            // holder's existing marker; only acquired custody publishes one.
            switch mailbox.helperUpdateDisposition() {
            case .unmarked: try mailbox.publishLeaseFlag(owner: owner, ttl: 120)
            case .active(let current) where current == owner, .stale(let current) where current == owner: break
            default: throw Failure("Guest helper update custody is unresolved")
            }
            return custody
        } catch {
            lease?.release(preserveMetadata: true)
            throw error
        }
    }

    private init(directory url: URL, mailbox: Mailbox, request: Request,
                 owner: String, generation: Int, lease: InputLease?) throws {
        self.lease = lease; self.mailbox = mailbox; self.owner = owner; location = url
        borrowedReceipt = lease == nil ? try InputLease.borrowedMetadataReceipt(
            directory: url, owner: owner, generation: generation) : nil
        directory = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw Failure("Cannot open guest operation evidence directory") }
        do {
            let out = openat(directory, InputLease.operationName,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard out >= 0 else { throw Failure("Guest operation fence already exists or cannot be published") }
            defer { close(out) }
            let data = try JSONSerialization.data(withJSONObject: [
                "schema": "terminal-mac.input-operation/1", "owner": owner,
                "operationID": request.id.uuidString, "action": request.action,
                "generation": generation])
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.write(out, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw Failure("Cannot write guest operation fence") }
                    offset += count
                }
            }
            guard fsync(out) == 0, fsync(directory) == 0 else {
                throw Failure("Guest operation fence publication is unconfirmed")
            }
            var info = stat()
            guard fstat(out, &info) == 0 else { throw Failure("Cannot identify published guest operation fence") }
            fenceReceipt = FenceReceipt(device: UInt64(info.st_dev), inode: UInt64(info.st_ino), bytes: data)
        } catch { close(directory); throw error }
    }
    deinit { close(directory) }

    public func perform<T>(_ effect: () async throws -> T) async throws -> T {
        guard !completed else { throw Failure("Guest custody operation cannot be replayed") }
        completed = true
        let result: T
        do { result = try await effect() }
        catch {
            if InputQueue.disposition(for: error) == .proceed { try finishConfirmed() }
            else { lease?.release(preserveMetadata: true) }
            throw error
        }
        try finishConfirmed()
        return result
    }
    /// Completion authority belongs only to the exact record published before
    /// this effect. Replaced or edited records remain unresolved evidence.
    private func requireOriginalFence() throws {
        guard let receipt = fenceReceipt else { throw Failure("Guest operation publication was not confirmed") }
        let input = openat(directory, InputLease.operationName, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard input >= 0 else { throw Failure("Guest operation fence disappeared") }
        defer { close(input) }
        var info = stat()
        guard fstat(input, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1,
              UInt64(info.st_dev) == receipt.device, UInt64(info.st_ino) == receipt.inode,
              info.st_size == receipt.bytes.count else { throw Failure("Guest operation fence was replaced") }
        var data = Data(count: receipt.bytes.count)
        try data.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.read(input, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw Failure("Cannot verify guest operation fence") }
                offset += count
            }
        }
        var named = stat()
        guard data == receipt.bytes,
              fstatat(directory, InputLease.operationName, &named, AT_SYMLINK_NOFOLLOW) == 0,
              UInt64(named.st_dev) == receipt.device, UInt64(named.st_ino) == receipt.inode else {
            throw Failure("Guest operation fence changed; preserve custody")
        }
    }

    private func finishConfirmed() throws {
        do {
            // The effect is confirmed: serialize cleanup with short admission
            // sections instead of stranding its records on ordinary contention.
            try InputLease.withAdmission(directory: location, wait: true) {
                func removeFence() throws {
                    try requireOriginalFence()
                    guard unlinkat(directory, InputLease.operationName, 0) == 0, fsync(directory) == 0 else {
                        throw Failure("Cannot durably release guest operation fence")
                    }
                }
                if let receipt = borrowedReceipt {
                    _ = try InputLease.closingMatches(directory: location, owner: owner)
                    try InputLease.finishBorrowed(directory: location, receipt: receipt) { orphaned in
                        try removeFence()
                        if orphaned { try mailbox.releaseLeaseFlagUnderAdmission(ownedBy: owner) }
                    }
                } else {
                    try removeFence()
                    try mailbox.releaseLeaseFlagUnderAdmission(ownedBy: owner)
                }
            }
            lease?.release()
        } catch {
            lease?.release(preserveMetadata: true)
            throw error
        }
    }
}
