import Testing
@testable import ConstExpr

private final class SourceSyntaxInvocationCounter: @unchecked Sendable {
    var count = 0
}

private func sourceSyntaxRegistry(
    counter: SourceSyntaxInvocationCounter? = nil
) -> ConstExprRegistry {
    ConstExprRegistry(
        ConstExprRegistration(
            name: "increment",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [Int.self],
            resultType: Int.self
        ) { _, arguments in
            counter?.count += 1
            return ConstExprValue(try arguments[0]!.require(Int.self) + 1)
        }
    )
}

@Test func stringInterpolationCanReceiveAConstantChildWithoutChangingItsSyntaxModel() {
    let result = ConstExprRunner(registry: sourceSyntaxRegistry()).rewrite(source: #"""
        let text = "value: \(increment(1))"
        """#)

    #expect(result.source == #"""
        let text = "value: \(2)"
        """#)
    #expect(result.diagnostics.isEmpty)
}

@Test func attachedAttributeAndExpressionMacroArgumentsRemainOpaque() {
    let counter = SourceSyntaxInvocationCounter()
    let result = ConstExprRunner(registry: sourceSyntaxRegistry(counter: counter)).rewrite(
        source: """
        @Example(argument: increment(1))
        struct Example {}
        let expression = #stringify(increment(2))
        """
    )

    #expect(result.source == """
        @Example(argument: increment(1))
        struct Example {}
        let expression = #stringify(increment(2))
        """)
    #expect(counter.count == 0)
}

@Test func conditionalCompilationBranchesNeverLeakAChosenConstant() {
    let counter = SourceSyntaxInvocationCounter()
    let source = """
        #if FIRST_CONFIGURATION
        let branchValue = increment(1)
        #else
        let branchValue = increment(2)
        #endif
        unknown(branchValue)
        """
    let result = ConstExprRunner(registry: sourceSyntaxRegistry(counter: counter)).rewrite(
        source: source
    )

    #expect(result.source == source)
    #expect(counter.count == 0)
}
