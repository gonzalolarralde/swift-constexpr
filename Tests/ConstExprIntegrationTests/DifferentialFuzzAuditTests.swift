import ConstExpr
import Testing

private final class DifferentialFuzzCounter: @unchecked Sendable {
    var value = 0
}

@Test func comparisonResultContextNeverLeaksIntoRegisteredOperands() {
    let counter = DifferentialFuzzCounter()
    let registry = ConstExprRegistry(
        ConstExprRegistration(
            name: "differentialFuzzIncrement",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [Int.self],
            resultType: Int.self
        ) { _, arguments in
            counter.value += 1
            return ConstExprValue(try arguments[0]!.require(Int.self) + 1)
        }
    )
    let result = ConstExprRunner(registry: registry).rewrite(source: """
        let direct: Bool = differentialFuzzIncrement(0) == 1
        let disjunction = false || (differentialFuzzIncrement(0) == 1)
        let conjunction = true && (differentialFuzzIncrement(0) == 1)
        let leftFirst = (differentialFuzzIncrement(0) == 1) || false
        """)

    #expect(result.source == """
        let direct: Bool = true
        let disjunction = true
        let conjunction = true
        let leftFirst = true
        """)
    #expect(result.diagnostics.isEmpty)
    #expect(counter.value == 4)
}

@Test func customPrefixResultContextNeverLeaksIntoItsRegisteredOperand() {
    let functionCounter = DifferentialFuzzCounter()
    let operatorCounter = DifferentialFuzzCounter()
    let registry = ConstExprRegistry(registrations: [
        ConstExprRegistration(
            name: "differentialFuzzMakeInt",
            kind: .function,
            resultType: Int.self
        ) { _, _ in
            functionCounter.value += 1
            return ConstExprValue(1)
        },
        .prefixOperator("%%%", operand: Int.self, result: Bool.self) { value in
            operatorCounter.value += 1
            return value == 1
        },
    ])

    let result = ConstExprRunner(registry: registry).rewrite(
        source: "let result: Bool = %%%differentialFuzzMakeInt()"
    )

    #expect(result.source == "let result: Bool = true")
    #expect(result.diagnostics.isEmpty)
    #expect(functionCounter.value == 1)
    #expect(operatorCounter.value == 1)
}

@Test func optionalInjectionOfOperatorResultsNeverBecomesAnOperandContext() {
    let result = ConstExprRunner(registry: .empty).rewrite(source: """
        let integer: Int? = 1 + 2
        let fixedWidth: UInt8? = 255 &+ 1
        let nestedFixedWidth: UInt8??? = 255 &+ 1
        let floating: Double? = 1.0 + 2.0
        let boolean: Bool? = true && false
        let string: String? = "a" + "b"
        let negated: Bool? = !true
        """)

    #expect(result.source == """
        let integer: Int? = (3) as Int?
        let fixedWidth: UInt8? = ((0) as Swift.UInt8) as UInt8?
        let nestedFixedWidth: UInt8??? = ((((0) as Swift.UInt8) as UInt8?) as UInt8??) as UInt8???
        let floating: Double? = (3.0) as Double?
        let boolean: Bool? = (false) as Bool?
        let string: String? = ("ab") as String?
        let negated: Bool? = (false) as Bool?
        """)
    #expect(result.diagnostics.isEmpty)
}
