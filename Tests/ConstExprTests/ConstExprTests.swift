import Testing
@testable import ConstExpr

private let incrementRegistration = ConstExprRegistration(
    name: "increment",
    kind: .function,
    parameterLabels: [nil],
    parameterTypes: [Int.self],
    resultType: Int.self
) { _, arguments in
    guard let argument = arguments[0] else {
        throw ConstExprValueError.typeMismatch(expected: "Int", actual: "missing")
    }
    return ConstExprValue(try argument.require(Int.self) + 1)
}

private let registry = ConstExprRegistry(registrations: [incrementRegistration])

@Test func nestedRegisteredCallsUseRewrittenArguments() {
    let source = "let result = increment(increment(5))"
    let result = ConstExprRunner(registry: registry).rewrite(source: source)

    #expect(result.source == "let result = 7")
    #expect(result.diagnostics.isEmpty)
}

@Test func unknownParentsKeepFoldedChildren() {
    let source = "let result = unknown(increment(5))"
    let result = ConstExprRunner(registry: registry).rewrite(source: source)

    #expect(result.source == "let result = unknown(6)")
}

@Test func operatorsRespectSwiftPrecedence() {
    let result = ConstExprRunner(registry: .empty).rewrite(
        source: "let result = 1 + 2 * 3"
    )

    #expect(result.source == "let result = 7")
}

@Test func sourceOnlyCompatibilityEntryPointDelegatesToRewrite() {
    let runner = ConstExprRunner(registry: registry)

    #expect(runner.run(input: "let result = increment(4)") == "let result = 5")
}

@Test func immutableBindingsPropagate() {
    let result = ConstExprRunner(registry: registry).rewrite(
        source: """
            let base = increment(1)
            let result = base * 3
            """
    )

    #expect(result.source == """
        let base = 2
        let result = 6
        """)
}
