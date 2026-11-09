import XCTest
@testable import TerminalMacCore

final class ViewerUpdateExitGateTests: XCTestCase {
    func testOnlyJoinedCleanViewerCanClearMarker() {
        XCTAssertTrue(ViewerUpdateExitGate.mayReleaseMarker(published: true, framesDrained: true,
                                                           inputInFlight: false, outcomeUnknown: false))
        for (published, drained, inFlight, unknown) in [
            (false, true, false, false),
            (true, false, false, false), // thrown/cancelled before frames.value
            (true, false, true, false),
            (true, true, true, false),  // an input remains in flight
            (true, true, false, true),  // error classified UNKNOWN
            (true, false, false, true)
        ] {
            XCTAssertFalse(ViewerUpdateExitGate.mayReleaseMarker(published: published,
                                                                 framesDrained: drained,
                                                                 inputInFlight: inFlight,
                                                                 outcomeUnknown: unknown))
        }
    }
}
