import ConstExpr

/// A deliberately small, side-effect-free lookalike for the subset of
/// PackageDescription.Product used by the consumer fixture. These values are
/// carried only inside the rewrite process; the rewritten manifest is compiled
/// against the real PackageDescription module.
@ConstExpr
public struct Product: Sendable {
    public let name: String
    public let targets: [String]
    public let kind: String

    public init(name: String, targets: [String], kind: String) {
        self.name = name
        self.targets = targets
        self.kind = kind
    }

    public static func library(
        name: String,
        targets: [String]
    ) -> Product {
        Product(name: name, targets: targets, kind: "library")
    }

    public static func executable(
        name: String,
        targets: [String]
    ) -> Product {
        Product(name: name, targets: targets, kind: "executable")
    }
}
