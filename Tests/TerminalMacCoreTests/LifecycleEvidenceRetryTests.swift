import Foundation
import XCTest
@testable import TerminalMacCore
@testable import TerminalMac

@MainActor
final class LifecycleEvidenceRetryTests: XCTestCase {
    func testUncertainLifecycleEvidenceIsNotRetriedBeforeOrAfterRename() throws {
        for failAfterRename in [false, true] {
            let root = testTemporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let directory = try AppServiceDirectory.open(root)
            var attempted = false, writes = 0, publication = "not-attempted"
            func publish() throws {
                try GuestAppService.publishLifecycleEvidence(attempted: &attempted) {
                    writes += 1
                    publication = "unconfirmed"
                    try directory.write(Data("evidence".utf8), named: "launch-lifecycle-operation.json", createOnly: true,
                        beforeRename: { if !failAfterRename { throw Failure("injected before rename") } },
                        afterRename: { if failAfterRename { throw Failure("injected after rename") } })
                    publication = "durable-lifecycle"
                }
            }
            XCTAssertThrowsError(try publish())
            // The service's failure handler may retain bounded diagnostics, but
            // must never enter the writer again for this operation.
            XCTAssertNoThrow(try publish())
            XCTAssertTrue(attempted)
            XCTAssertEqual(writes, 1)
            XCTAssertEqual(publication, "unconfirmed")
            let names = try directory.names(limit: 10)
            XCTAssertEqual(names.count, 1)
            XCTAssertEqual(names.contains("launch-lifecycle-operation.json"), failAfterRename)
        }
    }
}
