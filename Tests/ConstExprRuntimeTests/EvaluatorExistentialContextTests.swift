import Testing
@testable import ConstExpr

private protocol ExpectedContextValue {}

private struct ExpectedContextConformer: ExpectedContextValue {
    let value: Int
}

@Test func evaluatorDefersExistentialExpectedContextsUntilAValueExists() {
    final class Counter: @unchecked Sendable { var value = 0 }
    let counter = Counter()
    let registry = ConstExprRegistry(registrations: [
        ConstExprRegistration(
            name: "makeExpectedContextConformer",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [Int.self],
            resultType: ExpectedContextConformer.self
        ) { _, arguments in
            counter.value += 1
            return ConstExprValue(
                ExpectedContextConformer(
                    value: try arguments[0]!.require(Int.self)
                )
            )
        },
        ConstExprRegistration(
            name: "makeExpectedContextConformerArray",
            kind: .function,
            resultType: [ExpectedContextConformer].self
        ) { _, _ in
            counter.value += 1
            return ConstExprValue([
                ExpectedContextConformer(value: 5),
                ExpectedContextConformer(value: 6),
            ])
        },
        ConstExprRegistration(
            name: "makeOptionalExpectedContextConformer",
            kind: .function,
            resultType: ExpectedContextConformer?.self
        ) { _, _ in
            counter.value += 1
            return ConstExprValue(Optional(ExpectedContextConformer(value: 7)))
        },
        ConstExprRegistration(
            name: "acceptExpectedContextValue",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [(any ExpectedContextValue).self],
            resultType: String.self
        ) { _, arguments in
            let value = try arguments[0]!.require((any ExpectedContextValue).self)
            return ConstExprValue(
                "direct:\((value as! ExpectedContextConformer).value)"
            )
        },
        ConstExprRegistration(
            name: "acceptOptionalExpectedContextValue",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [(any ExpectedContextValue)?.self],
            resultType: String.self
        ) { _, arguments in
            let value = try arguments[0]!.require((any ExpectedContextValue)?.self)
            return ConstExprValue(value == nil ? "none" : "optional")
        },
        ConstExprRegistration(
            name: "acceptExpectedContextValues",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [[any ExpectedContextValue].self],
            resultType: Int.self
        ) { _, arguments in
            let values = try arguments[0]!.require([any ExpectedContextValue].self)
            return ConstExprValue(values.count)
        },
    ])

    let result = ConstExprRunner(registry: registry).rewrite(source: """
        let direct = acceptExpectedContextValue(makeExpectedContextConformer(1))
        let optional = acceptOptionalExpectedContextValue(makeExpectedContextConformer(2))
        let array = acceptExpectedContextValues([
            makeExpectedContextConformer(3),
            makeExpectedContextConformer(4),
        ])
        let boxedArray = acceptExpectedContextValues(makeExpectedContextConformerArray())
        let optionalCovariance = acceptOptionalExpectedContextValue(makeOptionalExpectedContextConformer())
        """)

    #expect(counter.value == 6)
    #expect(result.source == """
        let direct = "direct:1"
        let optional = "optional"
        let array = 2
        let boxedArray = 2
        let optionalCovariance = "optional"
        """)
    #expect(result.diagnostics.isEmpty)
}

@Test func evaluatorNeverUsesAnErasedDynamicValueAsAStaticConversionWitness() {
    final class Counter: @unchecked Sendable { var value = 0 }
    let counter = Counter()
    let concrete = ExpectedContextConformer(value: 5)
    let registry = ConstExprRegistry(registrations: [
        ConstExprRegistration(
            name: "makeErasedExpectedContextValue",
            kind: .function,
            resultType: Any.self
        ) { _, _ in
            counter.value += 1
            return ConstExprValue(
                concrete as Any,
                preservingStaticType: Any.self,
                sourceTypeName: "Any"
            )
        },
        ConstExprRegistration(
            name: "makeErasedExpectedContextArray",
            kind: .function,
            resultType: [Any].self
        ) { _, _ in
            counter.value += 1
            let values: [Any] = [concrete]
            return ConstExprValue(
                values,
                preservingStaticType: [Any].self,
                sourceTypeName: "[Any]"
            )
        },
        ConstExprRegistration(
            name: "makeErasedExpectedContextOptional",
            kind: .function,
            resultType: Any?.self
        ) { _, _ in
            counter.value += 1
            let value: Any? = concrete
            return ConstExprValue(
                value as Any,
                preservingStaticType: Any?.self,
                sourceTypeName: "Any?"
            )
        },
        ConstExprRegistration(
            name: "acceptExpectedContextValue",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [(any ExpectedContextValue).self],
            resultType: String.self
        ) { _, _ in ConstExprValue("wrong") },
        ConstExprRegistration(
            name: "acceptExpectedContextValues",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [[any ExpectedContextValue].self],
            resultType: String.self
        ) { _, _ in ConstExprValue("wrong") },
        ConstExprRegistration(
            name: "acceptOptionalExpectedContextValue",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [(any ExpectedContextValue)?.self],
            resultType: String.self
        ) { _, _ in ConstExprValue("wrong") },
    ])
    let source = """
        let direct = acceptExpectedContextValue(makeErasedExpectedContextValue())
        let array = acceptExpectedContextValues(makeErasedExpectedContextArray())
        let optional = acceptOptionalExpectedContextValue(makeErasedExpectedContextOptional())
        """

    let result = ConstExprRunner(registry: registry).rewrite(source: source)

    #expect(counter.value == 3)
    #expect(result.source == source)
    #expect(result.diagnostics.allSatisfy { $0.code == "no-matching-overload" })
}
