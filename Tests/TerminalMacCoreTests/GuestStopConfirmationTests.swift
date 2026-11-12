import XCTest
@testable import TerminalMacCore

final class GuestStopConfirmationTests: XCTestCase {
    func testPressIsAdmissibleOnlyWhileStoppingWithFreeLeaseAndAccessibleHelper() {
        for state in ["stopping", GuestStopConfirmation.awaitingState] {
            XCTAssertTrue(GuestStopConfirmation.admissible(runtimeState: state, lease: .allowed, helperAccessibility: "true"))
        }
        for state in ["running", "stopped", "paused", "starting", "error", ""] {
            XCTAssertFalse(GuestStopConfirmation.admissible(runtimeState: state, lease: .allowed, helperAccessibility: "true"), state)
        }
        for lease: InputLease.Admission in [.locked(owner: "other"), .lockedUnknown, .lockedUnresolved] {
            XCTAssertFalse(GuestStopConfirmation.admissible(runtimeState: "stopping", lease: lease, helperAccessibility: "true"))
        }
        for accessibility in ["false", "", nil] as [String?] {
            XCTAssertFalse(GuestStopConfirmation.admissible(runtimeState: "stopping", lease: .allowed, helperAccessibility: accessibility))
        }
    }

    func testOnlyTheLoginWindowShutDownButtonMatches() {
        XCTAssertTrue(GuestStopConfirmation.isSystemShutdownButton(ownerBundle: "com.apple.loginwindow", role: "AXButton", title: "Shut Down"))
        XCTAssertFalse(GuestStopConfirmation.isSystemShutdownButton(ownerBundle: "com.apple.loginwindow", role: "AXButton", title: "Restart"))
        XCTAssertFalse(GuestStopConfirmation.isSystemShutdownButton(ownerBundle: "com.apple.loginwindow", role: "AXButton", title: "Cancel"))
        XCTAssertFalse(GuestStopConfirmation.isSystemShutdownButton(ownerBundle: "com.apple.loginwindow", role: "AXStaticText", title: "Shut Down"))
        XCTAssertFalse(GuestStopConfirmation.isSystemShutdownButton(ownerBundle: "com.example.app", role: "AXButton", title: "Shut Down"))
        XCTAssertFalse(GuestStopConfirmation.isSystemShutdownButton(ownerBundle: nil, role: "AXButton", title: "Shut Down"))
        XCTAssertFalse(GuestStopConfirmation.isSystemShutdownButton(ownerBundle: "com.apple.loginwindow", role: "AXButton", title: "shut down"))
    }
}
