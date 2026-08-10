import ConstExpr

@ConstExpr
public struct Target: Sendable {
    /// SwiftPM declares this literal conformance and its factories in an
    /// extension. The example intentionally puts them in the primary body,
    /// documenting the current macro's no-extension-discovery boundary.
    @ConstExpr
    public enum Dependency: ExpressibleByStringLiteral, Sendable {
        case byName(String)
        case productReference(name: String, package: String)
        case targetReference(name: String)

        public init(stringLiteral value: String) {
            self = .byName(value)
        }

        public static func product(
            name: String,
            package: String
        ) -> Dependency {
            .productReference(name: name, package: package)
        }

        public static func target(name: String) -> Dependency {
            .targetReference(name: name)
        }
    }

    public let name: String
    public let dependencies: [Dependency]
    public let kind: String

    public init(
        name: String,
        dependencies: [Dependency] = [],
        kind: String
    ) {
        self.name = name
        self.dependencies = dependencies
        self.kind = kind
    }

    public static func target(
        name: String,
        dependencies: [Dependency] = []
    ) -> Target {
        Target(name: name, dependencies: dependencies, kind: "target")
    }

    public static func executableTarget(
        name: String,
        dependencies: [Dependency] = []
    ) -> Target {
        Target(name: name, dependencies: dependencies, kind: "executable")
    }
}
