import Foundation
import XCTest
@testable import TerminalMacCore
@testable import TerminalMac

@MainActor
final class MissingMachineStartupTests: XCTestCase {
    func testMissingMachineMCPStartupDoesNotCreateOrObstructMachineDirectory() async throws {
        let root = testTemporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("machines"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(root: root), directory = try store.directory("first")
        do {
            try await AgentServer(store: store, name: "first").run()
            XCTFail("A missing machine must fail before custody acquisition")
        } catch { XCTAssertTrue(error.localizedDescription.contains("does not exist")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        // Normal creation can still reserve a new directory without collision.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try store.save(Machine(name: "first", cpu: 2, memoryGiB: 2, diskGiB: 8))
        XCTAssertEqual(try store.load("first").name, "first")
    }
}
