import Testing
@testable import ConstExpr

private let literalContextRegistry = ConstExprRegistry(registrations: [
    ConstExprRegistration(
        name: "takesInt64",
        kind: .function,
        parameterLabels: [nil],
        parameterTypes: [Int64.self],
        resultType: String.self
    ) { _, arguments in
        ConstExprValue("wide:\(try arguments[0]!.require(Int64.self))")
    },
    ConstExprRegistration(
        name: "takesCharacter",
        kind: .function,
        parameterLabels: [nil],
        parameterTypes: [Character.self],
        resultType: String.self
    ) { _, arguments in
        ConstExprValue("character:\(try arguments[0]!.require(Character.self))")
    },
    ConstExprRegistration(
        name: "typedValue",
        kind: .function,
        resultType: Int.self,
        declarationID: "typedValue-int"
    ) { _, _ in ConstExprValue(3) },
    ConstExprRegistration(
        name: "typedValue",
        kind: .function,
        resultType: String.self,
        declarationID: "typedValue-string"
    ) { _, _ in ConstExprValue("three") },
])

@Test func evaluatorUsesLiteralProvenanceForCallsOnly() {
    let result = ConstExprRunner(registry: literalContextRegistry).rewrite(source: """
        let directInteger = takesInt64(1)
        let directCharacter = takesCharacter("x")
        let bound = 1
        let computedInteger = takesInt64(bound)
        """)

    #expect(result.source == """
        let directInteger = "wide:1"
        let directCharacter = "character:x"
        let bound = 1
        let computedInteger = takesInt64(1)
        """)
}

@Test func evaluatorPreservesExplicitBuiltinLiteralTypes() {
    let result = ConstExprRunner(registry: .empty).rewrite(source: """
        let wide: Int64 = 1
        let float: Float = 1.5
        let character: Character = "x"
        """)

    #expect(result.source == """
        let wide: Int64 = (1) as Swift.Int64
        let float: Float = (1.5) as Swift.Float
        let character: Character = ("x") as Swift.Character
        """)
}

@Test func evaluatorUsesExplicitReturnContextForReturnOnlyOverloads() {
    let result = ConstExprRunner(registry: literalContextRegistry).rewrite(source: """
        let text: String = typedValue()
        let number: Int = typedValue()
        let unresolved = typedValue()
        """)

    #expect(result.source == """
        let text: String = "three"
        let number: Int = 3
        let unresolved = typedValue()
        """)
    #expect(result.diagnostics.map(\.code) == ["ambiguous-overload"])
}

@Test func evaluatorPropagatesExplicitStructuralAndOptionalAnnotations() {
    let registry = ConstExprRegistry(registrations: [
        ConstExprRegistration(
            name: "arrayTotal",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [[Int].self],
            resultType: Int.self
        ) { _, arguments in
            ConstExprValue(try arguments[0]!.require([Int].self).reduce(0, +))
        },
        ConstExprRegistration(
            name: "dictionaryTotal",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [[String: Int].self],
            resultType: Int.self
        ) { _, arguments in
            ConstExprValue(try arguments[0]!.require([String: Int].self).values.reduce(0, +))
        },
        ConstExprRegistration(
            name: "optionalDescription",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [Int?.self],
            resultType: String.self
        ) { _, arguments in
            let value = try arguments[0]!.require(Int?.self)
            return ConstExprValue(value.map(String.init) ?? "nil")
        },
    ])
    let result = ConstExprRunner(registry: registry).rewrite(source: """
        let sugarArray: [Int] = [1, 2]
        let genericArray: Swift.Array<Swift.Int> = [3, 4]
        let dictionary: Swift.Dictionary<Swift.String, Swift.Int> = ["x": 5]
        let optional: Swift.Optional<Swift.Int> = 6
        let first = arrayTotal(sugarArray)
        let second = arrayTotal(genericArray)
        let third = dictionaryTotal(dictionary)
        let fourth = optionalDescription(optional)
        """)

    #expect(result.source == """
        let sugarArray: [Int] = [1, 2]
        let genericArray: Swift.Array<Swift.Int> = [3, 4]
        let dictionary: Swift.Dictionary<Swift.String, Swift.Int> = ["x": 5]
        let optional: Swift.Optional<Swift.Int> = (6) as Int?
        let first = 3
        let second = 7
        let third = 5
        let fourth = "6"
        """)
    #expect(result.diagnostics.isEmpty)
}
