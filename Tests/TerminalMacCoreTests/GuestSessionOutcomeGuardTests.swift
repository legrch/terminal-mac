import XCTest
@testable import TerminalMacCore

final class GuestSessionOutcomeGuardTests: XCTestCase {
    func testUnconfirmedEffectCannotBeFollowedByMoreInput() throws {
        var gate = GuestSessionOutcomeGuard()
        try gate.requireAllowed(action: "key")
        gate.markUnconfirmed()
        var effects = 0
        for action in ["key", "click", "type", "scroll", "move", "drag", "app-service", "unknown"] {
            XCTAssertThrowsError(try { try gate.requireAllowed(action: action); effects += 1 }())
        }
        XCTAssertEqual(effects, 0)
        for action in ["status", "screenshot"] { try gate.requireAllowed(action: action) }
        XCTAssertTrue(gate.isUnconfirmed)
        XCTAssertThrowsError(try gate.requireAllowed(action: "key"))
    }
}
