import Testing
@testable import ConstExpr

private struct OpaqueCollectionItem {
    let value: Int
}

private class OpaqueBaseItem {}
private final class OpaqueDerivedItem: OpaqueBaseItem {}

private let opaqueCollectionRegistry = ConstExprRegistry(registrations: [
    ConstExprRegistration(
        name: "makeOpaqueItem",
        kind: .function,
        parameterLabels: [nil],
        parameterTypes: [Int.self],
        resultType: OpaqueCollectionItem.self
    ) { _, arguments in
        ConstExprValue(
            OpaqueCollectionItem(value: try arguments[0]!.require(Int.self))
        )
    },
    ConstExprRegistration(
        name: "sumOpaqueItems",
        kind: .function,
        parameterLabels: [nil],
        parameterTypes: [[OpaqueCollectionItem].self],
        resultType: Int.self
    ) { _, arguments in
        let items = try arguments[0]!.require([OpaqueCollectionItem].self)
        return ConstExprValue(items.reduce(0) { $0 + $1.value })
    },
    ConstExprRegistration(
        name: "sumOpaqueDictionary",
        kind: .function,
        parameterLabels: [nil],
        parameterTypes: [[String: OpaqueCollectionItem].self],
        resultType: Int.self
    ) { _, arguments in
        let items = try arguments[0]!.require([String: OpaqueCollectionItem].self)
        return ConstExprValue(items.values.reduce(0) { $0 + $1.value })
    },
    ConstExprRegistration(
        name: "describeOptionalOpaqueItem",
        kind: .function,
        parameterLabels: [nil],
        parameterTypes: [OpaqueCollectionItem?.self],
        resultType: String.self
    ) { _, arguments in
        let item = try arguments[0]!.require(OpaqueCollectionItem?.self)
        return ConstExprValue(item.map { "item:\($0.value)" } ?? "none")
    },
    ConstExprRegistration(
        name: "makeOpaqueDerived",
        kind: .function,
        resultType: OpaqueDerivedItem.self
    ) { _, _ in
        ConstExprValue(OpaqueDerivedItem())
    },
    ConstExprRegistration(
        name: "describeOpaqueErasure",
        kind: .function,
        parameterLabels: [nil],
        parameterTypes: [OpaqueBaseItem.self],
        resultType: String.self,
        declarationID: "describe-base"
    ) { _, arguments in
        _ = try arguments[0]!.require(OpaqueBaseItem.self)
        return ConstExprValue("base")
    },
    ConstExprRegistration(
        name: "describeOpaqueErasure",
        kind: .function,
        parameterLabels: [nil],
        parameterTypes: [Any.self],
        resultType: String.self,
        declarationID: "describe-any"
    ) { _, arguments in
        _ = try arguments[0]!.require(Any.self)
        return ConstExprValue("any")
    },
    ConstExprRegistration(
        name: "acceptOpaqueBaseOnly",
        kind: .function,
        parameterLabels: [nil],
        parameterTypes: [OpaqueBaseItem.self],
        resultType: String.self
    ) { _, arguments in
        _ = try arguments[0]!.require(OpaqueBaseItem.self)
        return ConstExprValue("base-only")
    },
    ConstExprRegistration(
        name: "acceptAnyOnly",
        kind: .function,
        parameterLabels: [nil],
        parameterTypes: [Any.self],
        resultType: String.self
    ) { _, arguments in
        _ = try arguments[0]!.require(Any.self)
        return ConstExprValue("any-only")
    },
])

@Test func evaluatorDecodesOpaqueRegisteredValuesInsideStructuralContainers() {
    let result = ConstExprRunner(registry: opaqueCollectionRegistry).rewrite(source: """
        let array = sumOpaqueItems([makeOpaqueItem(1), makeOpaqueItem(2)])
        let dictionary = sumOpaqueDictionary([
            "first": makeOpaqueItem(3),
            "second": makeOpaqueItem(4),
        ])
        let optional = describeOptionalOpaqueItem(makeOpaqueItem(5))
        """)

    #expect(result.source == """
        let array = 3
        let dictionary = 7
        let optional = "item:5"
        """)
    #expect(result.diagnostics.isEmpty)
}

@Test func evaluatorUsesStaticClassUpcastsBeforeUniversalErasure() {
    let result = ConstExprRunner(registry: opaqueCollectionRegistry).rewrite(
        source: """
            let ranked = describeOpaqueErasure(makeOpaqueDerived())
            let upcast = acceptOpaqueBaseOnly(makeOpaqueDerived())
            let erased = acceptAnyOnly(makeOpaqueDerived())
            """
    )

    #expect(result.source == """
        let ranked = "base"
        let upcast = "base-only"
        let erased = "any-only"
        """)
    #expect(result.diagnostics.isEmpty)
}
