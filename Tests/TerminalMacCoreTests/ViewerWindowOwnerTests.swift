import Foundation
import XCTest
@testable import TerminalMacCore
@testable import TerminalMac

@MainActor
final class ViewerWindowOwnerTests: XCTestCase {
    func testRecoveryWindowUsesActualViewerLeaseAndRejectsForeignOwners() throws {
        let directory = testTemporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let lease = try InputLease.acquire(directory: directory, owner: TerminalViewer.leaseOwner, generation: 1)
        defer { lease.release() }
        let request = TerminalViewer.recoveryWindowRequest()
        XCTAssertEqual(request.action, "show")
        let probe = try InputLease.probe(directory: directory)
        XCTAssertNil(InputLease.nativeWindowDenial(probe: probe, windowOwner: request.arguments["leaseOwner"]))
        XCTAssertNotNil(InputLease.nativeWindowDenial(probe: probe, windowOwner: nil))
        XCTAssertNotNil(InputLease.nativeWindowDenial(probe: probe, windowOwner: "foreign"))
    }
}
