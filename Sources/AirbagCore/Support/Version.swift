import Foundation

/// Version information shared by the CLI and the app.
public enum AirbagVersion {
    /// Marketing version. Scripts/build-app.sh writes the same value into Info.plist.
    public static let marketing = "0.1.0"
    /// Hook protocol version; bumped when the stdin/stdout contract with agents changes.
    public static let hookProtocol = 1

    /// Human-readable version line, e.g. "airbag 0.1.0 (hook protocol 1)".
    public static var line: String { "airbag \(marketing) (hook protocol \(hookProtocol))" }
}
