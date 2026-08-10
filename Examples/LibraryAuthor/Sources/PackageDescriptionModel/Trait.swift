import ConstExpr

/// The SwiftPM 6.1 trait surface is a useful nested-literal example:
/// `Set<Trait>` is written with array-literal syntax, each Trait can come from
/// a string literal, and `.default` itself consumes a `Set<String>`.
@ConstExpr
public struct Trait: Hashable, ExpressibleByStringLiteral, Sendable {
    public let name: String
    public let description: String?
    public let enabledTraits: Set<String>

    public init(
        name: String,
        description: String? = nil,
        enabledTraits: Set<String> = []
    ) {
        self.name = name
        self.description = description
        self.enabledTraits = enabledTraits
    }

    public init(stringLiteral value: String) {
        self.init(name: value)
    }

    public static func `default`(enabledTraits: Set<String>) -> Trait {
        Trait(
            name: "default",
            description: "The default traits of this package.",
            enabledTraits: enabledTraits
        )
    }
}
