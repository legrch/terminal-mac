import XCTest
import Foundation
import CryptoKit
@testable import TerminalMacCore

/// Synthetic accepted metadata and process snapshots only. No test enumerates
/// host processes, opens an app, signals a PID, or invokes the guest helper.
final class AppLaunchIdentityTests: XCTestCase {
    private let installed = "/Applications/Sample.app"
    private let runtime = "Contents/Frameworks/UI Runtime.app"
    private let worker = "Contents/Frameworks/Worker.app"
    private let uid: UInt32 = 501
    private var floor: AppProcessKey { key(1, 100, 0) }
    private var empty: AppProcessCensus { census([]) }
    private func key(_ pid: Int32, _ seconds: UInt64 = 100, _ microseconds: UInt32 = 1) -> AppProcessKey {
        AppProcessKey(pid: pid, startSeconds: seconds, startMicroseconds: microseconds)
    }
    private func process(_ pid: Int32, parent: Int32 = 1, path: String,
                         seconds: UInt64 = 100, microseconds: UInt32 = 10, owner: UInt32 = 501) -> AppProcessSnapshot {
        AppProcessSnapshot(key: key(pid, seconds, microseconds), parentPID: parent,
                           uid: owner, executable: path.hasPrefix("/") ? path : installed + "/" + path)
    }
    private var root: AppProcessSnapshot { process(100, path: "Contents/Resources/app/engine", microseconds: 10) }
    private var primary: AppProcessSnapshot { process(200, parent: 100, path: runtime + "/Contents/MacOS/UI", microseconds: 20) }
    private var child: AppProcessSnapshot { process(300, parent: 200, path: worker + "/Contents/MacOS/Worker", microseconds: 30) }
    private func gui(_ process: AppProcessSnapshot, relative: String? = nil, id: String? = nil, regular: Bool = true) -> AppGUIObservation {
        AppGUIObservation(pid: process.key.pid,
                          bundlePath: installed + "/" + (relative ?? runtime),
                          bundleID: id ?? "org.fixture.ui", executable: process.executable, regular: regular)
    }
    private func census(_ entries: [AppProcessSnapshot], _ apps: [AppGUIObservation] = [], complete: Bool = true) -> AppProcessCensus {
        AppProcessCensus(processes: entries, applications: apps, complete: complete)
    }
    private func fixture() throws -> (AppServicePayload, [String: Data]) {
        func plist(id: String, executable: String, extra: [String: Any] = [:]) throws -> Data {
            var value: [String: Any] = ["CFBundleIdentifier": id, "CFBundleExecutable": executable,
                                       "CFBundleShortVersionString": "1.2.3", "CFBundlePackageType": "APPL"]
            value.merge(extra) { _, new in new }
            return try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
        }
        let files: [String: Data] = [
            "Contents/Info.plist": try plist(id: "org.fixture.outer", executable: "Start"),
            "Contents/MacOS/Start": Data("synthetic accepted launcher, never executed".utf8),
            "Contents/Resources/app/engine": Data("synthetic native root".utf8),
            runtime + "/Contents/Info.plist": try plist(id: "org.fixture.ui", executable: "UI"),
            runtime + "/Contents/MacOS/UI": Data("synthetic regular primary".utf8),
            worker + "/Contents/Info.plist": try plist(id: "org.fixture.worker", executable: "Worker", extra: ["LSUIElement": true]),
            worker + "/Contents/MacOS/Worker": Data("synthetic background child".utf8)
        ]
        var directories: Set<String> = []
        for path in files.keys {
            var parts = path.split(separator: "/").map(String.init)
            parts.removeLast()
            while !parts.isEmpty { directories.insert(parts.joined(separator: "/")); parts.removeLast() }
        }
        var entries: [[String: Any]] = directories.map {
            ["path": $0, "kind": "directory", "mode": 0o755, "bytes": 0, "sha256": "", "blob": "", "target": ""]
        }
        entries += files.map { path, data in
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            return ["path": path, "kind": "file", "mode": path.hasSuffix(".plist") ? 0o644 : 0o755,
                    "bytes": data.count, "sha256": digest, "blob": "blob-" + digest, "target": ""]
        }
        let document: [String: Any] = ["schema": AppServiceContract.payloadVersion, "appName": "Sample.app",
            "bundleID": "org.fixture.outer", "version": "1.2.3", "artifactSHA256": String(repeating: "a", count: 64),
            "archiveSHA256": String(repeating: "b", count: 64), "entries": entries]
        return (try JSONDecoder().decode(AppServicePayload.self, from: JSONSerialization.data(withJSONObject: document)), files)
    }
    private func plan() throws -> AppLaunchPlan {
        let (payload, files) = try fixture()
        return try AppLaunchPlan(installedPath: installed, payload: payload) { path, _ in try XCTUnwrap(files[path]) }
    }
    private func bind(_ entries: [AppProcessSnapshot]? = nil, apps: [AppGUIObservation]? = nil,
                      returned: AppProcessKey? = nil, before: AppProcessCensus? = nil) throws -> AppLaunchBinding {
        try AppLaunchIdentity.bind(plan: plan(), before: before ?? empty,
            after: census(entries ?? [root, primary, child], apps ?? [gui(primary), gui(child, relative: worker, id: "org.fixture.worker", regular: false)]),
            returned: returned ?? root.key, notBefore: floor, uid: uid)
    }
    private func expect(_ expected: AppLaunchIdentityError, _ body: () throws -> Void,
                        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) {
            XCTAssertEqual($0 as? AppLaunchIdentityError, expected, file: file, line: line)
        }
    }

    func testTornCensusReadIsReobservedWithoutAdoptingPartialInventory() throws {
        var reads = 0
        let result = try AppLaunchIdentity.stableCensus {
            reads += 1
            if reads == 1 { throw AppLaunchIdentityError.censusChanged }
            return self.census([self.root, self.primary])
        }
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(result.processes, [root, primary])
    }
    func testPersistentCensusChurnRemainsUnknownAfterBoundedReads() {
        var reads = 0
        expect(.censusChanged) {
            _ = try AppLaunchIdentity.stableCensus {
                reads += 1; throw AppLaunchIdentityError.censusChanged
            }
        }
        XCTAssertEqual(reads, 8)
    }
    func testChangedOwnedIdentityIsNeverRetriedAsCensusChurn() {
        var reads = 0
        expect(.changedIdentity) {
            _ = try AppLaunchIdentity.stableCensus {
                reads += 1; throw AppLaunchIdentityError.changedIdentity
            }
        }
        XCTAssertEqual(reads, 1)
    }
    func testPlanDerivesNestedIdentityFromAcceptedMetadataNotProductPaths() throws {
        let value = try plan()
        XCTAssertEqual(value.outerExecutable, installed + "/Contents/MacOS/Start")
        XCTAssertEqual(value.guiBundles.count, 2)
        XCTAssertTrue(value.acceptsExecutable(root.executable))
        XCTAssertEqual(value.guiBundle(path: installed + "/" + runtime, identifier: "org.fixture.ui",
                                      executable: primary.executable)?.bundleRelativePath, runtime)
        XCTAssertNil(value.guiBundle(path: installed + "/" + worker, identifier: "org.fixture.worker", executable: child.executable))
    }
    func testAcceptedAccessoryWithoutExecutableCannotBecomeGUIPrimary() throws {
        let (payload, files) = try fixture()
        let path = worker + "/Contents/Info.plist"
        var info = try XCTUnwrap(PropertyListSerialization.propertyList(from: files[path]!, format: nil) as? [String: Any])
        info.removeValue(forKey: "CFBundleExecutable")
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any])
        var entries = try XCTUnwrap(document["entries"] as? [[String: Any]])
        let index = try XCTUnwrap(entries.firstIndex { $0["path"] as? String == path })
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        entries[index]["bytes"] = data.count; entries[index]["sha256"] = hash; entries[index]["blob"] = "blob-" + hash
        document["entries"] = entries
        let accepted = try JSONDecoder().decode(AppServicePayload.self, from: JSONSerialization.data(withJSONObject: document))
        let selected = try AppLaunchPlan(installedPath: installed, payload: accepted) { name, _ in
            name == path ? data : try XCTUnwrap(files[name])
        }
        XCTAssertEqual(selected.guiBundles.count, 2)
        XCTAssertFalse(selected.guiBundles.contains { $0.bundleRelativePath == worker })
    }
    func testAlteredMetadataCannotInventCandidate() throws {
        let (payload, files) = try fixture()
        expect(.invalidPlan) {
            _ = try AppLaunchPlan(installedPath: installed, payload: payload) { path, _ in
                if path == self.runtime + "/Contents/Info.plist" { return Data("tampered".utf8) }
                return try XCTUnwrap(files[path])
            }
        }
    }
    func testForeignInstallationRootIsNotNormalizedIntoAcceptedPath() throws {
        let (payload, files) = try fixture()
        for path in ["/tmp/Sample.app", "/Applications/../Applications/Sample.app", "/Applications/Sample.app/"] {
            expect(.invalidPlan) {
                _ = try AppLaunchPlan(installedPath: path, payload: payload) { p, _ in try XCTUnwrap(files[p]) }
            }
        }
    }
    func testRootAndNestedRegularPrimaryAreDistinctAndBound() throws {
        let selected = try bind()
        XCTAssertEqual(selected.root, root)
        XCTAssertEqual(selected.primary, primary)
        XCTAssertEqual(selected.primaryBundle.identifier, "org.fixture.ui")
        XCTAssertEqual(selected.descendants, [child])
        XCTAssertEqual(selected.ancestry.map(\.key), [primary.key, root.key])
        XCTAssertNotEqual(selected.root.key.pid, selected.primary.key.pid)
    }
    func testLaunchServicesMayReturnNestedPrimaryRatherThanOuterRoot() throws {
        let selected = try bind(returned: primary.key)
        XCTAssertEqual(selected.root.key, root.key)
        XCTAssertEqual(selected.primary.key, primary.key)
    }
    func testOuterLaunchServicesProxyIsNeverSelectedAsUIPrimary() throws {
        let wrapper = AppGUIObservation(pid: root.key.pid, bundlePath: installed,
            bundleID: "org.fixture.outer", executable: installed + "/Contents/MacOS/Start", regular: true)
        let selected = try bind(apps: [wrapper, gui(primary)])
        XCTAssertEqual(selected.primary.key, primary.key)
        XCTAssertEqual(selected.root.key, root.key)
    }
    func testOuterProxyCannotHideAnUnrelatedRoot() throws {
        let extra = process(400, path: "Contents/Resources/app/engine", microseconds: 15)
        let wrapper = AppGUIObservation(pid: extra.key.pid, bundlePath: installed,
            bundleID: "org.fixture.outer", executable: installed + "/Contents/MacOS/Start", regular: true)
        expect(.ancestryUnconfirmed) { _ = try bind([root, primary, extra], apps: [wrapper, gui(primary)]) }
    }
    func testDirectOuterNativeAppUsesOneIdentityForBothRoles() throws {
        let direct = process(100, path: "Contents/MacOS/Start")
        let app = AppGUIObservation(pid: 100, bundlePath: installed, bundleID: "org.fixture.outer",
                                   executable: direct.executable, regular: true)
        let result = try bind([direct], apps: [app], returned: direct.key)
        XCTAssertEqual(result.root.key, result.primary.key)
    }
    func testPrelaunchLauncherBlocksEvenWithoutAnyGUIApplication() throws {
        expect(.preexisting) { try AppLaunchIdentity.preflight(plan: plan(), census: census([root])) }
    }
    func testSameBundleIdentifierElsewhereIsNotAuthorityToAdopt() throws {
        let foreign = process(99, path: "/Applications/Other.app/Contents/MacOS/UI", seconds: 90)
        let app = AppGUIObservation(pid: 99, bundlePath: "/Applications/Other.app", bundleID: "org.fixture.ui",
                                   executable: foreign.executable, regular: true)
        let prior = census([foreign], [app])
        XCTAssertNoThrow(try AppLaunchIdentity.preflight(plan: plan(), census: prior))
        XCTAssertEqual(try bind([root, primary, foreign], apps: [gui(primary), app], before: prior).primary.key, primary.key)
        expect(.returnedOutside) {
            _ = try bind([root, primary, foreign], apps: [gui(primary), app], returned: foreign.key)
        }
    }
    func testKernelExecutableMustBelongToAcceptedManifestNotJustBundlePrefix() throws {
        let invalid = process(100, path: "Contents/MacOS/UnacceptedInjectedFile")
        expect(.returnedOutside) { _ = try bind([invalid, primary], returned: invalid.key) }
    }
    func testGUIExecutableAndBoundedBundleMetadataMustAgree() throws {
        let wrong = gui(primary, id: "org.fixture.outer")
        expect(.metadataMismatch) { _ = try bind(apps: [wrong]) }
    }
    func testDuplicateRegularPrimariesRefuseRatherThanPickFirst() throws {
        let second = process(201, parent: 100, path: runtime + "/Contents/MacOS/UI", microseconds: 21)
        expect(.ambiguousPrimary) { _ = try bind([root, primary, second], apps: [gui(primary), gui(second)]) }
    }
    func testNoRegularPrimaryIsPendingNotImplicitSuccess() throws {
        expect(.noPrimary) { _ = try bind([root, primary], apps: [gui(primary, regular: false)]) }
    }
    func testReturnedPIDStartMismatchCannotBeAdopted() throws {
        expect(.returnedChanged) { _ = try bind(returned: key(root.key.pid, 101, 10)) }
    }
    func testPIDPresentBeforeLaunchCannotBeReusedForNewApp() throws {
        let old = process(100, path: "/usr/bin/unrelated", seconds: 90)
        expect(.staleIdentity) { _ = try bind(before: census([old])) }
    }
    func testProcessOlderThanDispatchBoundaryCannotBeAdopted() throws {
        let stale = process(100, path: "Contents/Resources/app/engine", seconds: 99)
        expect(.staleIdentity) { _ = try bind([stale, primary], returned: stale.key) }
    }
    func testMissingAcceptedAncestorDoesNotTurnNestedUIIntoDirectApp() throws {
        expect(.ancestryUnconfirmed) { _ = try bind([primary], apps: [gui(primary)], returned: primary.key) }
    }
    func testReturnedProcessMustBelongToPrimaryAncestorChain() throws {
        let other = process(400, path: "Contents/Resources/app/engine", microseconds: 15)
        expect(.ancestryUnconfirmed) { _ = try bind([root, primary, other], returned: other.key) }
    }
    func testRecycledParentNewerThanChildFailsAncestry() throws {
        let changedParent = process(100, path: "Contents/Resources/app/engine", microseconds: 40)
        expect(.ancestryUnconfirmed) { _ = try bind([changedParent, primary], returned: changedParent.key) }
    }
    func testCyclicAncestryCannotBeFollowedForever() throws {
        let cyclic = process(100, parent: 200, path: "Contents/Resources/app/engine", microseconds: 20)
        expect(.ancestryUnconfirmed) { _ = try bind([cyclic, primary], returned: cyclic.key) }
    }
    func testUnrelatedAcceptedBundleProcessRefusesEvenWithOneGUI() throws {
        let updater = process(400, path: "Contents/Resources/app/engine", microseconds: 40)
        expect(.unrelatedRoot) { _ = try bind([root, primary, updater]) }
    }
    func testAcceptedNonGUIUpdaterDescendantIsNotPrimary() throws {
        let updater = process(400, parent: 200, path: "Contents/Resources/app/engine", microseconds: 40)
        let selected = try bind([root, primary, child, updater])
        XCTAssertEqual(selected.primary.key, primary.key)
        XCTAssertEqual(selected.descendants.map(\.key.pid), [300, 400])
    }
    func testIncompleteAndDuplicateCensusCannotProveAbsence() throws {
        expect(.censusUnavailable) { try AppLaunchIdentity.preflight(plan: plan(), census: census([], complete: false)) }
        let p = process(2, path: "/usr/bin/a")
        expect(.censusUnavailable) { try AppLaunchIdentity.preflight(plan: plan(), census: census([p, p])) }
    }
    func testDifferentUserCannotSupplyAcceptedProcess() throws {
        let foreign = process(100, path: "Contents/Resources/app/engine", owner: 502)
        expect(.returnedOutside) { _ = try bind([foreign, primary], returned: foreign.key) }
    }
    func testMissingStartIdentityIsNotZeroOrCurrentTime() throws {
        let bad = process(100, path: "Contents/Resources/app/engine", seconds: 0)
        expect(.censusUnavailable) { _ = try bind([bad, primary], returned: bad.key) }
    }
    func testRootExitAndPrimaryExitAreIndependent() {
        XCTAssertEqual(AppLaunchIdentity.life(of: primary, observation: .originalExit(primary.key)), .exited)
        XCTAssertEqual(AppLaunchIdentity.life(of: root, observation: .live(root)), .running)
        XCTAssertEqual(AppLaunchIdentity.life(of: root, observation: .absent), .unknown)
        XCTAssertEqual(AppLaunchIdentity.life(of: root, observation: .unavailable), .unknown)
        XCTAssertEqual(AppLaunchIdentity.life(of: root, observation: .originalExit(primary.key)), .unknown)
        XCTAssertEqual(AppLaunchIdentity.life(of: root, observation: .originalExit(root.key)), .exited)
    }
    func testReusedPIDOrChangedExecutableIsNotOriginalRootExit() {
        let recycled = process(100, path: "Contents/Resources/app/engine", seconds: 101)
        let execChanged = process(100, path: "/usr/bin/other", microseconds: 10)
        XCTAssertEqual(AppLaunchIdentity.life(of: root, observation: .live(recycled)), .unknown)
        XCTAssertEqual(AppLaunchIdentity.life(of: root, observation: .originalExit(recycled.key)), .unknown)
        XCTAssertEqual(AppLaunchIdentity.life(of: root, observation: .live(execChanged)), .unknown)
    }
    func testNormalQuitCannotClaimAPreviouslyExitedOrUnknownProcess() {
        let states: [AppProcessLife] = [.running, .exited, .unknown]
        for root in states {
            for primary in states {
                if root == .running && primary == .running {
                    XCTAssertNoThrow(try AppLaunchIdentity.requireNormalQuitAdmission(root: root, primary: primary))
                } else {
                    expect(.exitUnconfirmed) {
                        try AppLaunchIdentity.requireNormalQuitAdmission(root: root, primary: primary)
                    }
                }
            }
        }
    }
    func testRevalidationCannotSwitchToAnotherPrimaryOrRoot() throws {
        let original = try bind()
        let newRoot = process(101, path: "Contents/Resources/app/engine", microseconds: 11)
        let newPrimary = process(201, parent: 101, path: runtime + "/Contents/MacOS/UI", microseconds: 21)
        let changed = try bind([newRoot, newPrimary], apps: [gui(newPrimary)], returned: newRoot.key)
        expect(.changedIdentity) { try AppLaunchIdentity.requireSameBinding(original, changed) }
        let noRenderer = try bind([root, primary], apps: [gui(primary)])
        XCTAssertNoThrow(try AppLaunchIdentity.requireSameBinding(original, noRenderer))
    }
    func testDiagnosticsDoNotEchoForeignPathsOrApplicationText() throws {
        let value = try plan()
        XCTAssertEqual(value.diagnosticPath(installed), ".")
        XCTAssertEqual(value.diagnosticPath(primary.executable), runtime + "/Contents/MacOS/UI")
        XCTAssertEqual(value.diagnosticPath("/Users/tester/private/SYNTHETIC_SECRET"), "outside-accepted-bundle")
        XCTAssertEqual(value.diagnosticPath(installed + "/Contents/../secret"), "invalid-path")
        XCTAssertEqual(value.diagnosticPath(nil), "unavailable")
    }
}
