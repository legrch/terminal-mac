/// Source-independent update-inhibitor release criterion for the terminal viewer.
/// A thrown/cancelled exit can bypass joining an outstanding frame request.
/// Missing the join, or any unconfirmed input, leaves the marker for recovery.
public enum ViewerUpdateExitGate {
    public static func mayReleaseMarker(published: Bool, framesDrained: Bool,
                                        inputInFlight: Bool, outcomeUnknown: Bool) -> Bool {
        published && framesDrained && !inputInFlight && !outcomeUnknown
    }
}
