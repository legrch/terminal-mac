import XCTest
import Foundation
import Darwin
@testable import TerminalMacCore

final class RuntimeLockTests: XCTestCase {
    func testMissingAndUnlockedAreStoppedAndHeldIsRunning() throws {
        let dir = testTemporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertFalse(try RuntimeLock.isHeld(in: dir))
        let path = dir.appendingPathComponent("runtime.lock").path
        let fd = open(path, O_CREAT | O_RDWR, 0o600)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        XCTAssertFalse(try RuntimeLock.isHeld(in: dir))
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        XCTAssertTrue(try RuntimeLock.isHeld(in: dir))
        XCTAssertEqual(flock(fd, LOCK_UN), 0)
    }

    func testUninspectableLockIsUnknownRatherThanStopped() throws {
        let dir = testTemporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("runtime.lock"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertThrowsError(try RuntimeLock.isHeld(in: dir))
    }
}
