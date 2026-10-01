/// Types shared between the app and the widget extension.
/// Contract: only generic readiness/task state and opaque identifiers.
/// Never document titles, prompts, source text, answer excerpts or credentials.
public enum DeskMateShared {
    public static let urlScheme = "deskmate"

    /// Info.plist key that carries the App Group identifier. `scripts/build-app.sh` stamps it into the app and the
    /// widget only when a team is given, because the group is Team-ID-prefixed. Without it there is no shared
    /// container, and both sides say so instead of guessing an identifier.
    public static let appGroupInfoKey = "DeskMateAppGroupIdentifier"
}
