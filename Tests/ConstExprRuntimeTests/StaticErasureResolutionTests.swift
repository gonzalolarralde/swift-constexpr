import Testing
@testable import ConstExpr

private protocol StaticErasedProtocol {}
private struct StaticErasedConcrete: StaticErasedProtocol {}
private class StaticErasedBase {}
private final class StaticErasedDerived: StaticErasedBase {}

/// These values are deliberately non-Sendable erased/class fixtures. The
/// runner invokes registrations synchronously in this test; the wrapper makes
/// that test-only assumption explicit instead of weakening the production API.
private struct StaticErasureFixture<Value>: @unchecked Sendable {
    let value: Value
}

private func staticErasureFactory(
    _ name: String,
    resultType: Any.Type,
    value: ConstExprValue
) -> ConstExprRegistration {
    let fixture = StaticErasureFixture(value: value)
    return ConstExprRegistration(
        name: name,
        kind: .function,
        resultType: resultType
    ) { _, _ in fixture.value }
}

private func staticErasureChoice(
    _ name: String,
    parameterType: Any.Type,
    result: String,
    invoked: (@Sendable () -> Void)? = nil
) -> ConstExprRegistration {
    ConstExprRegistration(
        name: name,
        kind: .function,
        parameterLabels: [nil],
        parameterTypes: [parameterType],
        resultType: String.self
    ) { _, _ in
        invoked?()
        return ConstExprValue(result)
    }
}

@Test func evaluatorNeverNarrowsARegisteredResultsDeclaredStaticType() {
    let existential: any StaticErasedProtocol = StaticErasedConcrete()
    let anyArray: [Any] = [1]
    let erasedArray: Any = [1]
    let optionalAny: Any? = 1
    let baseArray: [StaticErasedBase] = [StaticErasedDerived()]
    let baseOptional: StaticErasedBase? = StaticErasedDerived()

    let registry = ConstExprRegistry(registrations: [
        staticErasureFactory(
            "makeAny",
            resultType: Any.self,
            value: ConstExprValue(5 as Any, preservingStaticType: Any.self)
        ),
        staticErasureFactory(
            "makeExistential",
            resultType: (any StaticErasedProtocol).self,
            value: ConstExprValue(
                existential as Any,
                preservingStaticType: (any StaticErasedProtocol).self
            )
        ),
        staticErasureFactory(
            "makeAnyArray",
            resultType: [Any].self,
            value: ConstExprValue(anyArray)
        ),
        staticErasureFactory(
            "makeErasedArray",
            resultType: Any.self,
            value: ConstExprValue(erasedArray, preservingStaticType: Any.self)
        ),
        staticErasureFactory(
            "makeOptionalAny",
            resultType: Any?.self,
            value: ConstExprValue(optionalAny)
        ),
        staticErasureFactory(
            "makeBaseArray",
            resultType: [StaticErasedBase].self,
            value: ConstExprValue(baseArray)
        ),
        staticErasureFactory(
            "makeBaseOptional",
            resultType: StaticErasedBase?.self,
            value: ConstExprValue(baseOptional)
        ),

        staticErasureChoice("chooseAny", parameterType: Int.self, result: "wrong-int"),
        staticErasureChoice("chooseAny", parameterType: Any.self, result: "any"),
        staticErasureChoice(
            "chooseExistential",
            parameterType: StaticErasedConcrete.self,
            result: "wrong-concrete"
        ),
        staticErasureChoice(
            "chooseExistential",
            parameterType: (any StaticErasedProtocol).self,
            result: "existential"
        ),
        staticErasureChoice("chooseAnyArray", parameterType: [Int].self, result: "wrong-array"),
        staticErasureChoice("chooseAnyArray", parameterType: [Any].self, result: "any-array"),
        staticErasureChoice("chooseErasedArray", parameterType: [Int].self, result: "wrong-array"),
        staticErasureChoice("chooseErasedArray", parameterType: Any.self, result: "erased-array"),
        staticErasureChoice("chooseOptional", parameterType: Int?.self, result: "wrong-optional"),
        staticErasureChoice("chooseOptional", parameterType: Any?.self, result: "any-optional"),
        staticErasureChoice(
            "chooseBaseArray",
            parameterType: [StaticErasedDerived].self,
            result: "wrong-derived-array"
        ),
        staticErasureChoice(
            "chooseBaseArray",
            parameterType: [StaticErasedBase].self,
            result: "base-array"
        ),
        staticErasureChoice(
            "chooseBaseOptional",
            parameterType: StaticErasedDerived?.self,
            result: "wrong-derived-optional"
        ),
        staticErasureChoice(
            "chooseBaseOptional",
            parameterType: StaticErasedBase?.self,
            result: "base-optional"
        ),
    ])

    let result = ConstExprRunner(registry: registry).rewrite(source: """
        let any = chooseAny(makeAny())
        let existential = chooseExistential(makeExistential())
        let anyArray = chooseAnyArray(makeAnyArray())
        let erasedArray = chooseErasedArray(makeErasedArray())
        let optional = chooseOptional(makeOptionalAny())
        let baseArray = chooseBaseArray(makeBaseArray())
        let baseOptional = chooseBaseOptional(makeBaseOptional())
        """)

    #expect(result.source == """
        let any = "any"
        let existential = "existential"
        let anyArray = "any-array"
        let erasedArray = "erased-array"
        let optional = "any-optional"
        let baseArray = "base-array"
        let baseOptional = "base-optional"
        """)
    #expect(result.diagnostics.isEmpty)
}

@Test func evaluatorDoesNotUseADynamicPayloadWhenOnlyTheWrongOverloadIsRegistered() {
    final class Counter: @unchecked Sendable { var value = 0 }
    let counter = Counter()
    let registry = ConstExprRegistry(registrations: [
        staticErasureFactory(
            "makeAny",
            resultType: Any.self,
            value: ConstExprValue(5 as Any, preservingStaticType: Any.self)
        ),
        staticErasureChoice(
            "select",
            parameterType: Int.self,
            result: "wrong"
        ) {
            counter.value += 1
        },
    ])

    let result = ConstExprRunner(registry: registry).rewrite(
        source: "let value = select(makeAny())"
    )

    #expect(counter.value == 0)
    #expect(result.source == "let value = select(makeAny())")
    #expect(!result.source.contains("\"wrong\""))
    #expect(result.diagnostics.map(\.code) == ["no-matching-overload"])
}
