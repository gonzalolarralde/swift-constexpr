import ConstExpr

@ConstExpr
public struct SupportedPlatform: Sendable {
    @ConstExpr
    public enum MacOSVersion: String, Sendable {
        case v11
        case v12
        case v13
        case v14
        case v15
    }

    public let platform: String
    public let version: MacOSVersion

    public init(platform: String, version: MacOSVersion) {
        self.platform = platform
        self.version = version
    }

    public static func macOS(_ version: MacOSVersion) -> SupportedPlatform {
        SupportedPlatform(platform: "macOS", version: version)
    }
}
