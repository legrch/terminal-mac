import Darwin
import XCTest
@testable import TerminalMacCore
@testable import TerminalMac

/// Scripted native reads and original NOTE_EXIT delivery only; no real PIDs.
@MainActor
final class GuestProcessSamplingTests: XCTestCase {
    private func bsd(parent: UInt32 = 10, uid: UInt32 = 501,
                     seconds: UInt64 = 100, micros: UInt64 = 20) -> proc_bsdinfo {
        var info = proc_bsdinfo()
        info.pbi_pid = 42; info.pbi_ppid = parent; info.pbi_uid = uid
        info.pbi_start_tvsec = seconds; info.pbi_start_tvusec = micros
        return info
    }
    private var expected: AppProcessSnapshot {
        AppProcessSnapshot(key: AppProcessKey(pid: 42, startSeconds: 100, startMicroseconds: 20),
                           parentPID: 10, uid: 501, executable: "/Applications/Fixture.app/Contents/MacOS/Fixture")
    }
    private func sampling(reads: [proc_bsdinfo?], paths: [String]? = nil) -> GuestProcessCensus.Sampling {
        var index = 0, pathIndex = 0
        let paths = paths ?? [expected.executable, expected.executable]
        return GuestProcessCensus.Sampling(requireGuest: {}, bsd: { _ in
            guard index < reads.count else { XCTFail("Unexpected native read"); throw AppLaunchIdentityError.censusUnavailable }
            defer { index += 1 }; return reads[index]
        }, path: { _ in
            guard pathIndex < paths.count else { XCTFail("Unexpected path read"); throw AppLaunchIdentityError.censusUnavailable }
            defer { pathIndex += 1 }; return paths[pathIndex]
        }, pids: { [42] }, applications: { [] }, uid: 501)
    }
    func testReparentingDuringNativeSampleStillObservesOriginalExit() throws {
        let source = sampling(reads: [bsd(), bsd(parent: 1)])
        var didExit = false
        let observer = GuestOriginalProcessObserver(expected, sample: {
            try GuestProcessCensus.process(42, sampling: source)
        }, originalExit: { didExit })
        XCTAssertEqual(observer.life(), .running)
        didExit = true
        XCTAssertEqual(observer.life(), .exited)
        XCTAssertEqual(observer.life(), .exited)
    }
    func testNativeCensusTransitionPermanentlyPoisonsOriginalObserver() {
        var didExit = false, reads = 0
        let observer = GuestOriginalProcessObserver(expected, sample: {
            reads += 1; throw AppLaunchIdentityError.censusChanged
        }, originalExit: { didExit })
        XCTAssertEqual(observer.life(), .unknown)
        didExit = true
        XCTAssertEqual(observer.life(), .unknown)
        XCTAssertEqual(reads, 1)
    }
    func testMissingNativeSampleAllowsLaterOriginalExit() {
        var didExit = false
        let observer = GuestOriginalProcessObserver(expected, sample: { nil }, originalExit: { didExit })
        XCTAssertEqual(observer.life(), .exitPending)
        didExit = true
        XCTAssertEqual(observer.life(), .exited)
    }
}
