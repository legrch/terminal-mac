import Foundation
import XCTest
@testable import TerminalMacCore
@testable import TerminalMac

@MainActor
final class ViewerInputFreezeTests: XCTestCase {
    func testNewViewerInputAfterLostReplyDoesNotDispatch() async throws {
        let directory = testTemporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let box = try Mailbox(directory.appendingPathComponent("exchange"), create: true)
        let viewer = try TerminalViewer(directory: directory,
            machine: Machine(name: "fixture", cpu: 2, memoryGiB: 2, diskGiB: 8),
            graphics: "kitty", readOnly: false, requireInteractiveTerminal: false)
        viewer.enqueue(Request(action: "key", arguments: ["key": "cmd+v"], timeout: 0.01), label: "First paste")
        viewer.sendNextInput()
        for _ in 0..<200 {
            if viewer.guestOutcomeUnconfirmed { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertTrue(viewer.guestOutcomeUnconfirmed)
        viewer.enqueue("type", ["text": "later input"], label: "New text")
        viewer.enqueue(Request(action: "key", arguments: ["key": "cmd+v"]), label: "Repeated paste")
        viewer.sendNextInput()
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(try box.requests().isEmpty)
        XCTAssertTrue(viewer.guestOutcomeUnconfirmed)
    }
}
