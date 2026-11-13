import Foundation

/// Bind explicit transfers before asynchronous work can change clipboard ownership.
public enum ClipboardTransfer {
    public static func pasteRequest(_ text: String?, expectedRevision: Int, currentRevision: Int) throws -> Request {
        guard expectedRevision == currentRevision else {
            throw Failure("Host clipboard changed while capturing paste; nothing transferred")
        }
        guard let text, text.utf8.count <= 32768 else {
            throw Failure("Host clipboard must contain text up to 32 KiB")
        }
        return Request(action: "clipboard-paste", arguments: ["text": text], timeout: 5)
    }

    public static func guestCopyText(_ text: String?) throws -> String {
        guard let text, !text.isEmpty, text.utf8.count <= 32768 else {
            throw Failure("Guest selection must contain non-empty text up to 32 KiB")
        }
        return text
    }

    public static func copyText(_ text: String?, expectedRevision: Int, currentRevision: Int) throws -> String {
        guard expectedRevision == currentRevision else {
            throw Failure("Host clipboard changed during guest copy; newer contents preserved")
        }
        return try guestCopyText(text)
    }
}
