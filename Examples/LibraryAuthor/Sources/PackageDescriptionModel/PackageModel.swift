import ConstExpr

@ConstExpr
public final class Package {
    @ConstExpr
    public struct Dependency: Sendable {
        public let path: String

        public init(path: String) {
            self.path = path
        }

        public static func package(path: String) -> Dependency {
            Dependency(path: path)
        }
    }

    public let name: String
    public let platforms: [SupportedPlatform]?
    public let products: [Product]
    public let traits: Set<Trait>
    public let dependencies: [Dependency]
    public let targets: [Target]

    public init(
        name: String,
        platforms: [SupportedPlatform]? = nil,
        products: [Product] = [],
        traits: Set<Trait> = [],
        dependencies: [Dependency] = [],
        targets: [Target] = []
    ) {
        self.name = name
        self.platforms = platforms
        self.products = products
        self.traits = traits
        self.dependencies = dependencies
        self.targets = targets
    }
}
