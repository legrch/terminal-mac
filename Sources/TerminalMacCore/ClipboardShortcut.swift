import Foundation

/// macOS virtual key positions, independent of the active input language.
public enum ClipboardShortcut: Equatable {
    case copy, paste
    public static func resolve(keyCode: UInt16, command: Bool, control: Bool = false,
                               option: Bool = false, shift: Bool = false) -> ClipboardShortcut? {
        guard command, !control, !option, !shift else { return nil }
        switch keyCode {
        case 8: return .copy
        case 9: return .paste
        default: return nil
        }
    }
}
