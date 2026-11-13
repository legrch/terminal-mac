import Foundation

// Keep every disposable fixture inside the checkout, including under SwiftPM's
// test runner, which can replace the parent's TMPDIR on macOS.
let testTemporaryDirectory: URL = {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".build/test-fixtures", isDirectory: true)
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}()
