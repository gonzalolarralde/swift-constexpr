import Testing
@testable import ConstExpr

private struct PackageLiteralTrait: Hashable, ExpressibleByStringLiteral {
    let name: String

    init(stringLiteral value: String) {
        name = value
    }
}

@Test func setLiteralContextRecursivelyBuildsRegisteredStringLiteralElements() {
    let registry = ConstExprRegistry(registrations: [
        ConstExprRegistration(
            name: "PackageLiteralTrait",
            kind: .initializer,
            ownerType: PackageLiteralTrait.self,
            parameterLabels: ["stringLiteral"],
            parameterTypes: [String.self],
            resultType: PackageLiteralTrait.self
        ) { _, arguments in
            ConstExprValue(
                PackageLiteralTrait(
                    stringLiteral: try arguments[0]!.require(String.self)
                )
            )
        },
        ConstExprRegistration(
            name: "summarizeTraits",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [Set<PackageLiteralTrait>.self],
            resultType: String.self
        ) { _, arguments in
            let traits = try arguments[0]!.require(Set<PackageLiteralTrait>.self)
            return ConstExprValue(traits.map(\.name).sorted().joined(separator: ","))
        },
    ])

    let result = ConstExprRunner(registry: registry).rewrite(source: """
        let summary = summarizeTraits(["Metrics", "Logging", "Metrics"])
        """)

    #expect(result.source == """
        let summary = "Logging,Metrics"
        """)
    #expect(result.diagnostics.isEmpty)
}

