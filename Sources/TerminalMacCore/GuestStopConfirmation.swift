import Foundation

/// A virtual power-button press makes macOS show its own "shut down now?"
/// confirmation. The host never confirms it by default. The explicit
/// `stop --confirm-guest-dialog` may press exactly that system button once.
public enum GuestStopConfirmation {
    /// Host runtime state after the guest has not powered off within the window.
    public static let awaitingState = "stopping-awaiting-guest-confirmation"
    public static let guestAction = "confirm-shutdown-dialog"
    public static let ownerBundle = "com.apple.loginwindow"
    public static let buttonTitle = "Shut Down"
    public static let maximumDepth = 8

    /// A press is admissible only while a requested stop is in progress, no
    /// client holds or fences guest input, and a live helper has Accessibility.
    public static func admissible(runtimeState: String, lease: InputLease.Admission,
                                  helperAccessibility: String?) -> Bool {
        (runtimeState == "stopping" || runtimeState == awaitingState) &&
            lease == .allowed && helperAccessibility == "true"
    }

    /// Only the system shutdown confirmation's own button: loginwindow, AXButton,
    /// exact title. Any other application, role or title is never pressed.
    public static func isSystemShutdownButton(ownerBundle: String?, role: String?, title: String?) -> Bool {
        ownerBundle == Self.ownerBundle && role == "AXButton" && title == buttonTitle
    }
}
