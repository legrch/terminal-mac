import XCTest
import Foundation
import CryptoKit
@testable import TerminalMacCore

/// Pure accepted manifests, synthetic process snapshots, scripted exit events
/// and an injected original-deadline check. No app, host census, PID signalling,
/// VM, wall-clock delays, credentials or files are used by this suite.
final class AppQuitDrainTests: XCTestCase {
    private let installed = "/Applications/QuitFixture.app"
    private let runtime = "Contents/Frameworks/UI.app"
    private let helperBundle = "Contents/Frameworks/Worker.app"

    private func process(_ pid: Int32, parent: Int32 = 1, path: String,
                         seconds: UInt64 = 100, micros: UInt32 = 10,
                         uid: UInt32 = 501) -> AppProcessSnapshot {
        AppProcessSnapshot(key: AppProcessKey(pid: pid, startSeconds: seconds,
                                             startMicroseconds: micros),
                           parentPID: parent, uid: uid,
                           executable: path.hasPrefix("/") ? path : installed + "/" + path)
    }
    private var root: AppProcessSnapshot {
        process(100, path: "Contents/Resources/engine", micros: 10)
    }
    private var primary: AppProcessSnapshot {
        process(200, parent: 100, path: runtime + "/Contents/MacOS/UI", micros: 20)
    }
    private var helper: AppProcessSnapshot {
        process(300, parent: 200, path: helperBundle + "/Contents/MacOS/Worker", micros: 30)
    }
    private var primaryApp: AppGUIObservation {
        AppGUIObservation(pid: 200, bundlePath: installed + "/" + runtime,
                          bundleID: "org.fixture.ui", executable: primary.executable, regular: true)
    }
    private var helperApp: AppGUIObservation {
        AppGUIObservation(pid: 300, bundlePath: installed + "/" + helperBundle,
                          bundleID: "org.fixture.worker", executable: helper.executable, regular: false)
    }
    private func census(_ processes: [AppProcessSnapshot] = [],
                        _ applications: [AppGUIObservation] = [],
                        complete: Bool = true) -> AppProcessCensus {
        AppProcessCensus(processes: processes, applications: applications, complete: complete)
    }
    private func plan() throws -> AppLaunchPlan {
        func plist(_ id: String, _ executable: String, accessory: Bool = false) throws -> Data {
            var info: [String: Any] = ["CFBundleIdentifier": id, "CFBundleExecutable": executable,
                                       "CFBundleShortVersionString": "1.0.0", "CFBundlePackageType": "APPL"]
            if accessory { info["LSUIElement"] = true }
            return try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        }
        let files: [String: Data] = [
            "Contents/Info.plist": try plist("org.fixture.outer", "Start"),
            "Contents/MacOS/Start": Data("synthetic launcher".utf8),
            "Contents/Resources/engine": Data("synthetic root".utf8),
            runtime + "/Contents/Info.plist": try plist("org.fixture.ui", "UI"),
            runtime + "/Contents/MacOS/UI": Data("synthetic GUI".utf8),
            helperBundle + "/Contents/Info.plist": try plist("org.fixture.worker", "Worker", accessory: true),
            helperBundle + "/Contents/MacOS/Worker": Data("synthetic helper".utf8)
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
        let document: [String: Any] = [
            "schema": AppServiceContract.payloadVersion, "appName": "QuitFixture.app",
            "bundleID": "org.fixture.outer", "version": "1.0.0",
            "artifactSHA256": String(repeating: "a", count: 64),
            "archiveSHA256": String(repeating: "b", count: 64), "entries": entries
        ]
        let payload = try JSONDecoder().decode(AppServicePayload.self,
            from: JSONSerialization.data(withJSONObject: document))
        return try AppLaunchPlan(installedPath: installed, payload: payload) { path, _ in
            try XCTUnwrap(files[path])
        }
    }
    private func fixture() throws -> (AppLaunchPlan, AppLaunchBinding, AppProcessCensus, AppQuitDrain) {
        let plan = try plan()
        let live = census([root, primary, helper], [primaryApp, helperApp])
        let binding = try AppLaunchIdentity.bind(plan: plan, before: census(), after: live,
            returned: root.key,
            notBefore: AppProcessKey(pid: 1, startSeconds: 100, startMicroseconds: 0), uid: 501)
        return (plan, binding, live, try AppQuitDrain(plan: plan, binding: binding, beforeQuit: live))
    }
    private func expect(_ error: AppLaunchIdentityError, _ body: () throws -> Void,
                        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) {
            XCTAssertEqual($0 as? AppLaunchIdentityError, error, file: file, line: line)
        }
    }
    private enum TestStop: Error, Equatable { case originalDeadline }

    func testOriginalRootAndPrimaryExitMatrixNeverSubstitutesAbsenceForExit() throws {
        let (_, _, _, drain) = try fixture()
        let states: [AppProcessLife] = [.running, .exited, .unknown]
        for root in states {
            for primary in states {
                if root == .unknown || primary == .unknown {
                    expect(.observationUnavailable) {
                        _ = try drain.progress(root: root, primary: primary, census: census())
                    }
                } else if root == .exited && primary == .exited {
                    XCTAssertEqual(try drain.progress(root: root, primary: primary, census: census()), .quiescent)
                    expect(.censusUnavailable) { _ = try drain.progress(root: root, primary: primary) }
                } else {
                    XCTAssertEqual(try drain.progress(root: root, primary: primary),
                                   .originalExitsPending(root: root, primary: primary))
                }
            }
        }
    }

    func testExactKnownHelperAfterBothExitsIsWaitingNotUnknownOrSuccess() throws {
        let (_, _, _, drain) = try fixture()
        XCTAssertEqual(try drain.progress(root: .exited, primary: .exited,
                                         census: census([helper], [helperApp])),
                       .inventoryPending(processes: 1, applications: 1))
        let reparented = process(300, parent: 1, path: helper.executable, micros: 30)
        XCTAssertEqual(try drain.progress(root: .exited, primary: .exited,
                                         census: census([reparented])),
                       .inventoryPending(processes: 1, applications: 0))
        XCTAssertEqual(try drain.progress(root: .exited, primary: .exited, census: census()), .quiescent)
    }

    func testRegistryEntrySurvivesWithoutAnyLivePIDAndCannotBeFilteredOut() throws {
        let (_, _, _, drain) = try fixture()
        XCTAssertEqual(try drain.progress(root: .exited, primary: .exited,
                                         census: census([], [primaryApp, helperApp])),
                       .inventoryPending(processes: 0, applications: 2))
        let noLongerRegular = AppGUIObservation(pid: primaryApp.pid,
            bundlePath: primaryApp.bundlePath, bundleID: primaryApp.bundleID,
            executable: primaryApp.executable, regular: false)
        XCTAssertEqual(try drain.progress(root: .exited, primary: .exited,
                                         census: census([], [noLongerRegular])),
                       .inventoryPending(processes: 0, applications: 1))
    }

    func testStillEnumeratedOriginalIdentityIsNotMistakenForEmptyInventory() throws {
        let (_, _, _, drain) = try fixture()
        XCTAssertEqual(try drain.progress(root: .exited, primary: .exited,
                                         census: census([root, primary])),
                       .inventoryPending(processes: 2, applications: 0))
    }

    func testRecycledPIDChangedExecutableOrUIDIsNeverWaitable() throws {
        let (_, _, _, drain) = try fixture()
        for original in [root, primary, helper] {
            let reused = AppProcessSnapshot(
                key: AppProcessKey(pid: original.key.pid, startSeconds: 101, startMicroseconds: 0),
                parentPID: 1, uid: original.uid, executable: original.executable)
            let execChanged = AppProcessSnapshot(key: original.key, parentPID: 1,
                uid: original.uid, executable: "/usr/bin/unrelated")
            let ownerChanged = AppProcessSnapshot(key: original.key, parentPID: 1,
                uid: 502, executable: original.executable)
            for changed in [reused, execChanged, ownerChanged] {
                expect(.changedIdentity) {
                    _ = try drain.progress(root: .exited, primary: .exited, census: census([changed]))
                }
            }
        }
    }

    func testNewAcceptedProcessCannotBeAdoptedAsAnotherQuittingHelper() throws {
        let (_, _, _, drain) = try fixture()
        let fresh = process(400, parent: 1, path: helper.executable, micros: 60)
        expect(.unrelatedRoot) {
            _ = try drain.progress(root: .exited, primary: .exited, census: census([fresh]))
        }
        let newUnacceptedExecutable = process(401, path: "Contents/MacOS/Unaccepted", micros: 61)
        expect(.unrelatedRoot) {
            _ = try drain.progress(root: .exited, primary: .exited, census: census([newUnacceptedExecutable]))
        }
    }

    func testChangedOrNewAcceptedRegistryIdentityFailsImmediately() throws {
        let (_, _, _, drain) = try fixture()
        let variants = [
            AppGUIObservation(pid: 200, bundlePath: primaryApp.bundlePath,
                              bundleID: "org.someone.else", executable: primaryApp.executable, regular: true),
            AppGUIObservation(pid: 200, bundlePath: "/Applications/Foreign.app",
                              bundleID: primaryApp.bundleID, executable: "/usr/bin/foreign", regular: false),
            AppGUIObservation(pid: 400, bundlePath: helperApp.bundlePath,
                              bundleID: helperApp.bundleID, executable: helperApp.executable, regular: false),
            AppGUIObservation(pid: 200, bundlePath: "", bundleID: "", executable: "", regular: false)
        ]
        for app in variants {
            expect(.metadataMismatch) {
                _ = try drain.progress(root: .exited, primary: .exited, census: census([], [app]))
            }
        }
    }

    func testIncompleteOrMalformedCensusIsNotAnEmptySuccessfulInventory() throws {
        let (_, _, _, drain) = try fixture()
        let noStart = process(300, path: helper.executable, seconds: 0)
        let invalidApp = AppGUIObservation(pid: 0, bundlePath: "", bundleID: "", executable: "", regular: false)
        for sample in [census(complete: false), census([helper, helper]),
                       census([], [helperApp, helperApp]), census([noStart]), census([], [invalidApp])] {
            expect(.censusUnavailable) {
                _ = try drain.progress(root: .exited, primary: .exited, census: sample)
            }
        }
    }

    func testUnrelatedPathsDoNotBecomeOwnedDescendantsOrBlockAcceptedByteDrain() throws {
        let (_, _, _, drain) = try fixture()
        let other = process(500, path: "/Applications/Other.app/Contents/MacOS/Other", seconds: 90)
        let registry = AppGUIObservation(pid: 500, bundlePath: "/Applications/Other.app",
            bundleID: "org.fixture.ui", executable: other.executable, regular: true)
        XCTAssertEqual(try drain.progress(root: .exited, primary: .exited,
                                         census: census([other], [registry])), .quiescent)
        // A shared bundle ID is not a process ownership relationship.
    }

    func testPreQuitBaselineMustBeCompleteAndCoverEveryAcceptedProcess() throws {
        let (plan, binding, baseline, _) = try fixture()
        expect(.censusUnavailable) {
            _ = try AppQuitDrain(plan: plan, binding: binding,
                                beforeQuit: census(baseline.processes, baseline.applications, complete: false))
        }
        expect(.changedIdentity) {
            _ = try AppQuitDrain(plan: plan, binding: binding, beforeQuit: census([root, primary], [primaryApp]))
        }
        let fresh = process(400, parent: 200, path: helper.executable, micros: 60)
        expect(.unrelatedRoot) {
            _ = try AppQuitDrain(plan: plan, binding: binding,
                                beforeQuit: census(baseline.processes + [fresh], baseline.applications))
        }
    }

    func testOuterLauncherRegistryMetadataIsPreservedWithoutTreatingItAsGUIOwner() throws {
        let (plan, binding, baseline, _) = try fixture()
        let outer = AppGUIObservation(pid: root.key.pid, bundlePath: installed,
            bundleID: "org.fixture.outer", executable: plan.outerExecutable, regular: true)
        let drain = try AppQuitDrain(plan: plan, binding: binding,
            beforeQuit: census(baseline.processes, baseline.applications + [outer]))
        XCTAssertEqual(try drain.progress(root: .exited, primary: .exited,
                                         census: census([], [outer])),
                       .inventoryPending(processes: 0, applications: 1))
    }

    func testCloseIndependentlyRechecksExitsAndWholeAcceptedInventory() throws {
        let (_, _, _, drain) = try fixture()
        XCTAssertEqual(try drain.progress(root: .exited, primary: .exited, census: census()), .quiescent)
        XCTAssertNoThrow(try drain.requireQuiescent(root: .exited, primary: .exited, census: census()))
        expect(.exitUnconfirmed) {
            try drain.requireQuiescent(root: .exited, primary: .exited, census: census([], [primaryApp]))
        }
        expect(.exitUnconfirmed) {
            try drain.requireQuiescent(root: .exited, primary: .exited, census: census([helper]))
        }
        expect(.observationUnavailable) {
            try drain.requireQuiescent(root: .unknown, primary: .exited, census: census())
        }
        let fresh = process(400, path: helper.executable, micros: 80)
        expect(.unrelatedRoot) {
            try drain.requireQuiescent(root: .exited, primary: .exited, census: census([fresh]))
        }
    }

    func testDirectNativeAppWithOneOriginalIdentityStillRequiresRegistryDrain() throws {
        let plan = try plan()
        let direct = process(100, path: "Contents/MacOS/Start")
        let app = AppGUIObservation(pid: 100, bundlePath: installed,
            bundleID: "org.fixture.outer", executable: direct.executable, regular: true)
        let live = census([direct], [app])
        let binding = try AppLaunchIdentity.bind(plan: plan, before: census(), after: live,
            returned: direct.key,
            notBefore: AppProcessKey(pid: 1, startSeconds: 100, startMicroseconds: 0), uid: 501)
        XCTAssertEqual(binding.root.key, binding.primary.key)
        let drain = try AppQuitDrain(plan: plan, binding: binding, beforeQuit: live)
        XCTAssertEqual(try drain.progress(root: .exited, primary: .exited,
                                         census: census([], [app])),
                       .inventoryPending(processes: 0, applications: 1))
        XCTAssertEqual(try drain.progress(root: .exited, primary: .exited, census: census()), .quiescent)
    }

    @MainActor
    func testProductionLoopTerminatesOnceThenSettlesProcessAndRegistryEvidence() async throws {
        let (_, _, _, drain) = try fixture()
        var effects = 0, tick = 0, inventories = 0
        var observations: [AppQuitDrainProgress] = []
        try await drain.run(check: {
            if tick >= 6 { throw TestStop.originalDeadline }
        }, terminatePrimary: {
            effects += 1; return true
        }, originals: {
            if effects == 0 { return (.running, .running) }
            if tick == 0 { return (.running, .exited) }
            if tick == 1 { return (.exited, .running) }
            return (.exited, .exited)
        }, inventory: {
            inventories += 1
            if tick == 2 { return self.census([self.helper], [self.primaryApp, self.helperApp]) }
            if tick == 3 { return self.census([], [self.primaryApp]) }
            return self.census()
        }, nextObservation: {
            tick += 1
        }, observed: { observations.append($0) })
        XCTAssertEqual(effects, 1)
        XCTAssertEqual(inventories, 3)
        XCTAssertEqual(tick, 4)
        XCTAssertEqual(observations, [
            .originalExitsPending(root: .running, primary: .exited),
            .originalExitsPending(root: .exited, primary: .running),
            .inventoryPending(processes: 1, applications: 2),
            .inventoryPending(processes: 0, applications: 1), .quiescent])
    }

    @MainActor
    func testFalseTerminateReturnNeverTriggersAnotherEffectOrCensus() async throws {
        let (_, _, _, drain) = try fixture()
        var effects = 0, inventories = 0, waits = 0
        do {
            try await drain.run(check: {}, terminatePrimary: { effects += 1; return false },
                originals: { (.running, .running) }, inventory: { inventories += 1; return self.census() },
                nextObservation: { waits += 1 })
            XCTFail("false terminate must remain unknown")
        } catch { XCTAssertEqual(error as? AppLaunchIdentityError, .exitUnconfirmed) }
        XCTAssertEqual(effects, 1); XCTAssertEqual(inventories, 0); XCTAssertEqual(waits, 0)
    }

    @MainActor
    func testAlreadyExitedOrUnknownOriginalPreventsNormalQuitEffect() async throws {
        let (_, _, _, drain) = try fixture()
        let pairs: [(AppProcessLife, AppProcessLife)] = [(.running, .exited), (.exited, .exited),
                                                       (.unknown, .running), (.running, .unknown)]
        for pair in pairs {
            var effects = 0
            do {
                try await drain.run(check: {}, terminatePrimary: { effects += 1; return true },
                    originals: { pair }, inventory: { self.census() }, nextObservation: {})
                XCTFail("original observers must be live before Quit")
            } catch { XCTAssertEqual(error as? AppLaunchIdentityError, .exitUnconfirmed) }
            XCTAssertEqual(effects, 0)
        }
    }

    @MainActor
    func testOriginalExitDuringFinalCustodyCheckPreventsTerminationEffect() async throws {
        let (_, _, _, drain) = try fixture()
        var effects = 0, checks = 0, inventories = 0
        var root: AppProcessLife = .running
        do {
            try await drain.run(check: {
                checks += 1
                if checks == 2 { root = .exited }
            }, terminatePrimary: { effects += 1; return true },
            originals: { (root, .running) },
            inventory: { inventories += 1; return self.census() }, nextObservation: {})
            XCTFail("a root that exited during the final check is not normal-Quit admission")
        } catch { XCTAssertEqual(error as? AppLaunchIdentityError, .exitUnconfirmed) }
        XCTAssertEqual(effects, 0); XCTAssertEqual(inventories, 0); XCTAssertEqual(checks, 2)
    }

    @MainActor
    func testUnknownObserverAfterTerminateFailsWithoutInventoryOrRetry() async throws {
        let (_, _, _, drain) = try fixture()
        var effects = 0, inventories = 0, waits = 0
        do {
            try await drain.run(check: {}, terminatePrimary: { effects += 1; return true },
                originals: { effects == 0 ? (.running, .running) : (.unknown, .exited) },
                inventory: { inventories += 1; return self.census() }, nextObservation: { waits += 1 })
            XCTFail("unknown NOTE_EXIT observer must refuse")
        } catch { XCTAssertEqual(error as? AppLaunchIdentityError, .observationUnavailable) }
        XCTAssertEqual(effects, 1); XCTAssertEqual(inventories, 0); XCTAssertEqual(waits, 0)
    }

    @MainActor
    func testUnreadableTornOrChangedInventoryErrorIsNotCaughtAsWaitable() async throws {
        let (_, _, _, drain) = try fixture()
        for expected in [AppLaunchIdentityError.censusUnavailable, .censusChanged, .changedIdentity] {
            var effects = 0, inventories = 0, waits = 0
            do {
                try await drain.run(check: {}, terminatePrimary: { effects += 1; return true },
                    originals: { effects == 0 ? (.running, .running) : (.exited, .exited) },
                    inventory: { inventories += 1; throw expected }, nextObservation: { waits += 1 })
                XCTFail("an unknown census must not be retried as a positive survivor")
            } catch { XCTAssertEqual(error as? AppLaunchIdentityError, expected) }
            XCTAssertEqual(effects, 1); XCTAssertEqual(inventories, 1); XCTAssertEqual(waits, 0)
        }
    }

    @MainActor
    func testIncompleteReturnedInventoryCannotFallThroughToLaterEmptySample() async throws {
        let (_, _, _, drain) = try fixture()
        var effects = 0, inventories = 0, waits = 0
        do {
            try await drain.run(check: {}, terminatePrimary: { effects += 1; return true },
                originals: { effects == 0 ? (.running, .running) : (.exited, .exited) },
                inventory: {
                    inventories += 1
                    return self.census(complete: inventories != 1)
                }, nextObservation: { waits += 1 })
            XCTFail("incomplete empty sample must be rejected immediately")
        } catch { XCTAssertEqual(error as? AppLaunchIdentityError, .censusUnavailable) }
        XCTAssertEqual(effects, 1); XCTAssertEqual(inventories, 1); XCTAssertEqual(waits, 0)
    }

    @MainActor
    func testPersistentKnownHelperOrRegistryExpiresOnlyAgainstOriginalDeadline() async throws {
        let (_, _, _, drain) = try fixture()
        for registryOnly in [false, true] {
            var effects = 0, tick = 0, inventories = 0
            var observations: [AppQuitDrainProgress] = []
            do {
                try await drain.run(check: {
                    if tick >= 4 { throw TestStop.originalDeadline }
                }, terminatePrimary: { effects += 1; return true },
                originals: { effects == 0 ? (.running, .running) : (.exited, .exited) },
                inventory: {
                    inventories += 1
                    return registryOnly ? self.census([], [self.primaryApp]) : self.census([self.helper])
                }, nextObservation: { tick += 1 }, observed: { observations.append($0) })
                XCTFail("persistent survivor cannot become complete because time elapsed")
            } catch { XCTAssertEqual(error as? TestStop, .originalDeadline) }
            XCTAssertEqual(effects, 1); XCTAssertEqual(inventories, 4); XCTAssertEqual(tick, 4)
            XCTAssertFalse(observations.contains(.quiescent))
        }
    }

    @MainActor
    func testDeadlineCrossedDuringEmptyInventoryStillFailsAfterRead() async throws {
        let (_, _, _, drain) = try fixture()
        var effects = 0, expired = false, waits = 0
        var observations: [AppQuitDrainProgress] = []
        do {
            try await drain.run(check: { if expired { throw TestStop.originalDeadline } },
                terminatePrimary: { effects += 1; return true },
                originals: { effects == 0 ? (.running, .running) : (.exited, .exited) },
                inventory: { expired = true; return self.census() },
                nextObservation: { waits += 1 }, observed: { observations.append($0) })
            XCTFail("a late empty census must not extend the original deadline")
        } catch { XCTAssertEqual(error as? TestStop, .originalDeadline) }
        XCTAssertEqual(effects, 1); XCTAssertEqual(waits, 0); XCTAssertTrue(observations.isEmpty)
    }

    @MainActor
    func testCancellationDuringWaitStopsWithoutAnotherMutationOrSample() async throws {
        let (_, _, _, drain) = try fixture()
        var effects = 0, inventories = 0, waits = 0
        do {
            try await drain.run(check: {}, terminatePrimary: { effects += 1; return true },
                originals: { effects == 0 ? (.running, .running) : (.exited, .exited) },
                inventory: { inventories += 1; return self.census([self.helper]) },
                nextObservation: { waits += 1; throw CancellationError() })
            XCTFail("cancellation must leave the outstanding Quit unconfirmed")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(effects, 1); XCTAssertEqual(inventories, 1); XCTAssertEqual(waits, 1)
    }

    @MainActor
    func testCancellationOrDeadlineBeforeDispatchSendsNoTermination() async throws {
        let (_, _, _, drain) = try fixture()
        for cancelled in [false, true] {
            var effects = 0, inventories = 0
            do {
                try await drain.run(check: {
                    if cancelled { throw CancellationError() }
                    throw TestStop.originalDeadline
                }, terminatePrimary: { effects += 1; return true },
                originals: { (.running, .running) }, inventory: { inventories += 1; return self.census() },
                nextObservation: {})
                XCTFail("expired/cancelled admission must refuse")
            } catch {
                if cancelled { XCTAssertTrue(error is CancellationError) }
                else { XCTAssertEqual(error as? TestStop, .originalDeadline) }
            }
            XCTAssertEqual(effects, 0); XCTAssertEqual(inventories, 0)
        }
    }

    @MainActor
    func testWaitableHelperThenChangedIdentityStopsWithoutTryingTheNextSample() async throws {
        let (_, _, _, drain) = try fixture()
        var effects = 0, inventories = 0, waits = 0
        let recycled = process(300, parent: 1, path: helper.executable, seconds: 101, micros: 0)
        do {
            try await drain.run(check: {
                if waits > 3 { throw TestStop.originalDeadline }
            }, terminatePrimary: { effects += 1; return true },
            originals: { effects == 0 ? (.running, .running) : (.exited, .exited) },
            inventory: {
                inventories += 1
                if inventories == 1 { return self.census([self.helper]) }
                if inventories == 2 { return self.census([recycled]) }
                return self.census() // must never be consulted after changed identity
            }, nextObservation: { waits += 1 })
            XCTFail("positive survivor waiting must not swallow a later changed identity")
        } catch { XCTAssertEqual(error as? AppLaunchIdentityError, .changedIdentity) }
        XCTAssertEqual(effects, 1); XCTAssertEqual(inventories, 2); XCTAssertEqual(waits, 1)
    }

    @MainActor
    func testObserverBecomingUnknownDuringCensusCannotAttestCompletion() async throws {
        let (_, _, _, drain) = try fixture()
        var effects = 0, reads = 0, inventories = 0, waits = 0
        do {
            try await drain.run(check: {}, terminatePrimary: { effects += 1; return true },
                originals: {
                    reads += 1
                    if effects == 0 { return (.running, .running) }
                    return reads >= 4 ? (.unknown, .exited) : (.exited, .exited)
                }, inventory: { inventories += 1; return self.census() },
                nextObservation: { waits += 1 })
            XCTFail("changed exit observation cannot pass using an earlier event")
        } catch { XCTAssertEqual(error as? AppLaunchIdentityError, .observationUnavailable) }
        XCTAssertEqual(effects, 1); XCTAssertEqual(inventories, 1); XCTAssertEqual(waits, 0)
    }
}
