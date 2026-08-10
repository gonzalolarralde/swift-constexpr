import Testing
@testable import ConstExpr

@Test func explicitFixedWidthAndFloatingContextsDriveOperatorEvaluation() {
    let result = ConstExprRunner(registry: .empty).rewrite(source: """
        let unsigned: UInt8 = 255 &+ 1
        let signed: Int8 = 127 &+ 1
        let division: Double = 1 / 2
        """)

    #expect(result.source == """
        let unsigned: UInt8 = (0) as Swift.UInt8
        let signed: Int8 = (-128) as Swift.Int8
        let division: Double = 0.5
        """)
    #expect(result.diagnostics.isEmpty)
}

@Test func explicitFixedWidthContextDiagnosesCheckedOverflow() {
    let result = ConstExprRunner(registry: .empty).rewrite(
        source: "let value: Int8 = 127 + 1"
    )

    #expect(result.source == "let value: Int8 = 127 + 1")
    #expect(result.diagnostics.map(\.code) == ["integer-overflow"])
}

@Test func signedAndMaximumWidthLiteralsHonorExplicitAnnotations() {
    let result = ConstExprRunner(registry: .empty).rewrite(source: """
        let negative: Int64 = -9
        let maximum: UInt64 = 18_446_744_073_709_551_615
        """)

    #expect(result.source == """
        let negative: Int64 = (-9) as Swift.Int64
        let maximum: UInt64 = (18446744073709551615) as Swift.UInt64
        """)
    #expect(result.diagnostics.isEmpty)
}

@Test func tryQuestionMarkPreservesItsOptionalResultType() {
    enum Failure: Error { case expected }
    let registry = ConstExprRegistry(registrations: [
        ConstExprRegistration(
            name: "mayThrow",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [Bool.self],
            resultType: Int.self,
            isThrowing: true
        ) { _, arguments in
            guard try arguments[0]!.require(Bool.self) else { throw Failure.expected }
            return ConstExprValue(5)
        },
    ])

    let result = ConstExprRunner(registry: registry).rewrite(source: """
        let success = try? mayThrow(true)
        let failure = try? mayThrow(false)
        """)

    #expect(result.source == """
        let success = (5) as Int?
        let failure = try? mayThrow(false)
        """)
    #expect(result.diagnostics.map(\.code) == ["evaluation-threw"])
}

@Test func macroExpansionArgumentsAreOpaqueToTheSourceEvaluator() {
    final class Counter: @unchecked Sendable { var value = 0 }
    let counter = Counter()
    let registration = ConstExprRegistration(
        name: "increment",
        kind: .function,
        parameterLabels: [nil],
        parameterTypes: [Int.self],
        resultType: Int.self
    ) { _, arguments in
        counter.value += 1
        return ConstExprValue(try arguments[0]!.require(Int.self) + 1)
    }

    let result = ConstExprRunner(registry: ConstExprRegistry(registration)).rewrite(
        source: "let result = #stringify(increment(1))"
    )

    #expect(result.source == "let result = #stringify(increment(1))")
    #expect(counter.value == 0)
}

@Test func aTrailingClosurePreventsAccidentalOuterRegistrationMatching() {
    final class Counter: @unchecked Sendable { var value = 0 }
    let counter = Counter()
    let registration = ConstExprRegistration(
        name: "increment",
        kind: .function,
        parameterLabels: [nil],
        parameterTypes: [Int.self],
        resultType: Int.self
    ) { _, arguments in
        counter.value += 1
        return ConstExprValue(try arguments[0]!.require(Int.self) + 1)
    }

    let result = ConstExprRunner(registry: ConstExprRegistry(registration)).rewrite(
        source: "increment(1) { consume() }"
    )

    #expect(result.source == "increment(1) { consume() }")
    #expect(counter.value == 0)
}
