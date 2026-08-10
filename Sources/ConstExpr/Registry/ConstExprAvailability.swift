/// Version used by a source availability domain such as `_PackageDescription`.
public struct ConstExprAvailabilityVersion: Sendable, Hashable, Comparable {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int = 0, patch: Int = 0) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}

/// Availability requirements recorded for one generated registration.
public struct ConstExprAvailability: Sendable, Hashable {
    public typealias Version = ConstExprAvailabilityVersion

    public let domain: String
    public let introduced: Version?
    public let deprecated: Version?
    public let obsoleted: Version?
    public let isUnavailable: Bool
    public let isDeprecated: Bool

    public init(
        domain: String,
        introduced: Version? = nil,
        deprecated: Version? = nil,
        obsoleted: Version? = nil,
        isUnavailable: Bool = false,
        isDeprecated: Bool = false
    ) {
        self.domain = domain
        self.introduced = introduced
        self.deprecated = deprecated
        self.obsoleted = obsoleted
        self.isUnavailable = isUnavailable
        self.isDeprecated = isDeprecated
    }
}

/// Versions active for one source-evaluation request.
public struct ConstExprAvailabilityContext: Sendable, Hashable {
    public typealias Version = ConstExprAvailabilityVersion

    public let versions: [String: Version]

    public init(versions: [String: Version] = [:]) {
        self.versions = versions
    }
}

public extension _ConstExprRuntime {
    typealias Availability = ConstExprAvailability
    typealias AvailabilityVersion = ConstExprAvailabilityVersion
    typealias AvailabilityContext = ConstExprAvailabilityContext
}
