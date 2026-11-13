import Foundation
import CryptoKit

/// The only executable/bundle identities admitted by a native launch. Produced
/// from the already accepted physical manifest and bounded hash-checked plist
/// bytes, never from a host-selected executable name, shell or command line.
public struct AppLaunchPlan: Equatable {
    public struct GUIBundle: Codable, Equatable {
        public let bundleRelativePath: String
        public let identifier: String
        public let executableRelativePath: String
        public init(bundleRelativePath: String, identifier: String, executableRelativePath: String) {
            self.bundleRelativePath = bundleRelativePath; self.identifier = identifier
            self.executableRelativePath = executableRelativePath
        }
    }
    public let installedPath: String
    public let executableRelativePaths: Set<String>
    public let guiBundles: [GUIBundle]
    public let outerExecutable: String

    public init(installedPath: String, payload: AppServicePayload,
                readMetadata: (String, Int) throws -> Data) throws {
        try payload.validate()
        guard installedPath == AppServiceContract.installationRoot + "/" + payload.appName else {
            throw AppLaunchIdentityError.invalidPlan
        }
        self.installedPath = installedPath
        let entries = Dictionary(uniqueKeysWithValues: payload.entries.map { ($0.path, $0) })
        let executablePaths = Set(payload.entries.filter { $0.kind == "file" && $0.mode & 0o111 != 0 }.map(\.path))
        guard !executablePaths.isEmpty, executablePaths.count <= 512 else {
            throw AppLaunchIdentityError.invalidPlan
        }
        executableRelativePaths = executablePaths
        let suffix = "/Contents/Info.plist"
        let plists = payload.entries.filter {
            $0.path == "Contents/Info.plist" ||
                ($0.path.hasSuffix(suffix) && String($0.path.dropLast(suffix.count)).hasSuffix(".app"))
        }.sorted { $0.path < $1.path }
        guard !plists.isEmpty, plists.count <= 64 else { throw AppLaunchIdentityError.invalidPlan }
        var candidates: [GUIBundle] = []
        var outer: String?
        for entry in plists {
            guard entry.kind == "file", entry.bytes > 0, entry.bytes <= 65536 else {
                throw AppLaunchIdentityError.invalidPlan
            }
            let data = try readMetadata(entry.path, 65536)
            guard data.count == entry.bytes,
                  SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == entry.sha256,
                  let info = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
                  let identifier = info["CFBundleIdentifier"] as? String,
                  !identifier.isEmpty, identifier.utf8.count <= 160,
                  identifier.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) ||
                      (97...122).contains($0) || [45, 46].contains($0) }),
                  info["CFBundlePackageType"] == nil || info["CFBundlePackageType"] as? String == "APPL" else {
                throw AppLaunchIdentityError.invalidPlan
            }
            let bundle = entry.path == "Contents/Info.plist" ? "" : String(entry.path.dropLast(suffix.count))
            // Vendor accessory bundles may omit CFBundleExecutable entirely.
            // Their accepted bytes are still checked above, but they can never
            // supply the regular GUI primary. The outer launcher remains strict.
            if !bundle.isEmpty && (info["LSBackgroundOnly"] as? Bool == true || info["LSUIElement"] as? Bool == true) {
                continue
            }
            guard let executable = info["CFBundleExecutable"] as? String,
                  AppServiceContract.path(executable), !executable.contains("/") else {
                throw AppLaunchIdentityError.invalidPlan
            }
            let relative = (bundle.isEmpty ? "" : bundle + "/") + "Contents/MacOS/" + executable
            guard entries[relative]?.kind == "file", executablePaths.contains(relative) else {
                throw AppLaunchIdentityError.invalidPlan
            }
            if bundle.isEmpty {
                guard identifier == payload.bundleID,
                      info["CFBundleShortVersionString"] as? String == payload.version else {
                    throw AppLaunchIdentityError.invalidPlan
                }
                outer = installedPath + "/" + relative
            }
            // A declared background/accessory bundle cannot become a regular
            // UI primary even if a stale LaunchServices object says otherwise.
            if info["LSBackgroundOnly"] as? Bool != true && info["LSUIElement"] as? Bool != true {
                candidates.append(GUIBundle(bundleRelativePath: bundle, identifier: identifier,
                                            executableRelativePath: relative))
            }
        }
        guard let outer, !candidates.isEmpty else { throw AppLaunchIdentityError.invalidPlan }
        outerExecutable = outer; guiBundles = candidates
    }

    public func contains(_ executable: String) -> Bool {
        executable.hasPrefix(installedPath + "/")
    }
    public func containsBundle(_ bundle: String) -> Bool {
        bundle == installedPath || bundle.hasPrefix(installedPath + "/")
    }
    public func acceptsExecutable(_ executable: String) -> Bool {
        guard contains(executable) else { return false }
        return executableRelativePaths.contains(String(executable.dropFirst(installedPath.count + 1)))
    }
    /// LaunchServices can retain outer-bundle metadata after its declared
    /// script execs an accepted native launcher. Such a process is NOT selected
    /// as a GUI primary. Admission must still prove it is an ancestor of the
    /// unique nested primary (and connected to the returned launch identity).
    public func isOuterLauncherMetadata(_ app: AppGUIObservation, process: AppProcessSnapshot) -> Bool {
        guard let outer = guiBundles.first(where: { $0.bundleRelativePath.isEmpty }) else { return false }
        return app.bundlePath == installedPath && app.bundleID == outer.identifier &&
            acceptsExecutable(process.executable) && process.executable != outerExecutable &&
            (app.executable == outerExecutable || app.executable == process.executable)
    }

    public func guiBundle(path: String, identifier: String, executable: String) -> GUIBundle? {
        guiBundles.first {
            path == installedPath + ($0.bundleRelativePath.isEmpty ? "" : "/" + $0.bundleRelativePath) &&
                identifier == $0.identifier && executable == installedPath + "/" + $0.executableRelativePath
        }
    }
    /// Diagnostics never disclose arbitrary unrelated process paths. Accepted
    /// tree paths are safe manifest names; other paths get a closed category.
    public func diagnosticPath(_ path: String?) -> String {
        guard let path else { return "unavailable" }
        if path == installedPath { return "." }
        guard contains(path) else { return "outside-accepted-bundle" }
        let relative = String(path.dropFirst(installedPath.count + 1))
        return AppServiceContract.path(relative) ? relative : "invalid-path"
    }
}
