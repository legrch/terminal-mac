import Foundation

/// Live-only timebase: guest wall-clock synchronization cannot shorten or
/// extend a finite service lifetime. Never reconstructed from disk receipts.
public struct AppServiceTimebase {
    private let wallAnchor: Date
    private var lastElapsed: TimeInterval = 0

    public init(wallAnchor: Date) throws {
        guard wallAnchor.timeIntervalSince1970.isFinite,
              wallAnchor.timeIntervalSince1970 > 0 else {
            throw AppServiceContract.refuse("APP_SERVICE_UNRESOLVED")
        }
        self.wallAnchor = wallAnchor
    }

    public mutating func sample(elapsed: TimeInterval) throws -> Date {
        guard elapsed.isFinite, elapsed >= lastElapsed else {
            throw AppServiceContract.refuse("APP_SERVICE_UNRESOLVED")
        }
        let result = wallAnchor.addingTimeInterval(elapsed)
        guard result.timeIntervalSince1970.isFinite else {
            throw AppServiceContract.refuse("APP_SERVICE_UNRESOLVED")
        }
        lastElapsed = elapsed
        return result
    }
}
