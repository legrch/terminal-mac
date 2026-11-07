import Foundation

/// macOS virtual key positions, independent of the active input language.
public enum ClipboardShortcut: Equatable {
    case copy, paste, pasteGuest
    public static func resolve(keyCode: UInt16, command: Bool, control: Bool = false,
                               option: Bool = false, shift: Bool = false) -> ClipboardShortcut? {
        guard command, !option, !shift else { return nil }
        if control { return keyCode == 9 ? .pasteGuest : nil }
        switch keyCode {
        case 8: return .copy
        case 9: return .paste
        default: return nil
        }
    }
}
