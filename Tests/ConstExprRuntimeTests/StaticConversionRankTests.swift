import Testing
@testable import ConstExpr

private class StaticRankBase {}
private final class StaticRankDerived: StaticRankBase {}

private class StaticRankRoot {}
private class StaticRankMiddle: StaticRankRoot {}
private final class StaticRankLeaf: StaticRankMiddle {}

private protocol StaticRankProtocol {}
private struct StaticRankConformer: StaticRankProtocol {}

private protocol StaticRankClassProtocol: AnyObject {}
private final class StaticRankClassConformer: StaticRankClassProtocol {}

@Test func evaluatorPrefersShallowerOptionalInjectionForValuesAndNil() {
    let registry = ConstExprRegistry(registrations: [
        ConstExprRegistration(
            name: "optionalDepthChoice",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [Int?.self],
            resultType: String.self
        ) { _, arguments in
            _ = try arguments[0]!.require(Int?.self)
            return ConstExprValue("single")
        },
        ConstExprRegistration(
            name: "optionalDepthChoice",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [Int??.self],
            resultType: String.self
        ) { _, arguments in
            _ = try arguments[0]!.require(Int??.self)
            return ConstExprValue("double")
        },
    ])

    let result = ConstExprRunner(registry: registry).rewrite(source: """
        let value = optionalDepthChoice(5)
        let nilValue = optionalDepthChoice(nil)
        """)

    #expect(result.source == """
        let value = "single"
        let nilValue = "single"
        """)
    #expect(result.diagnostics.isEmpty)
}

@Test func evaluatorRanksOptionalCovarianceAheadOfOptionalInjectionForResults() {
    let registry = ConstExprRegistry(registrations: [
        ConstExprRegistration(
            name: "staticRankFactory",
            kind: .function,
            resultType: StaticRankDerived?.self,
            declarationID: "static-rank-derived-optional"
        ) { _, _ in
            ConstExprValue(Optional<StaticRankDerived>.none)
        },
        ConstExprRegistration(
            name: "staticRankFactory",
            kind: .function,
            resultType: StaticRankBase.self,
            declarationID: "static-rank-base"
        ) { _, _ in
            ConstExprValue(StaticRankBase())
        },
        ConstExprRegistration(
            name: "describeStaticRankOptional",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [StaticRankBase?.self],
            resultType: String.self
        ) { _, arguments in
            let value = try arguments[0]!.require(StaticRankBase?.self)
            return ConstExprValue(value == nil ? "nil" : "some")
        },
    ])

    let result = ConstExprRunner(registry: registry).rewrite(
        source: "let value = describeStaticRankOptional(staticRankFactory())"
    )

    #expect(result.source == "let value = \"nil\"")
    #expect(result.diagnostics.isEmpty)
}

@Test func evaluatorPrefersTheNearestSuperclassAndAnyObjectOverAny() {
    let registry = ConstExprRegistry(registrations: [
        ConstExprRegistration(
            name: "makeStaticRankLeaf",
            kind: .function,
            resultType: StaticRankLeaf.self
        ) { _, _ in
            ConstExprValue(StaticRankLeaf())
        },
        ConstExprRegistration(
            name: "staticClassChoice",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [StaticRankMiddle.self],
            resultType: String.self
        ) { _, arguments in
            _ = try arguments[0]!.require(StaticRankMiddle.self)
            return ConstExprValue("middle")
        },
        ConstExprRegistration(
            name: "staticClassChoice",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [StaticRankRoot.self],
            resultType: String.self
        ) { _, arguments in
            _ = try arguments[0]!.require(StaticRankRoot.self)
            return ConstExprValue("root")
        },
        ConstExprRegistration(
            name: "staticErasureChoice",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [AnyObject.self],
            resultType: String.self
        ) { _, arguments in
            _ = try arguments[0]!.require(AnyObject.self)
            return ConstExprValue("object")
        },
        ConstExprRegistration(
            name: "staticErasureChoice",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [Any.self],
            resultType: String.self
        ) { _, arguments in
            _ = try arguments[0]!.require(Any.self)
            return ConstExprValue("any")
        },
        ConstExprRegistration(
            name: "makeStaticRankClassExistential",
            kind: .function,
            resultType: (any StaticRankClassProtocol).self
        ) { _, _ in
            let classExistential: any StaticRankClassProtocol = StaticRankClassConformer()
            return ConstExprValue(
                classExistential as Any,
                preservingStaticType: (any StaticRankClassProtocol).self,
                sourceTypeName: "any StaticRankClassProtocol",
                isStaticallyAnyObject: true
            )
        },
        ConstExprRegistration(
            name: "staticClassExistentialErasureChoice",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [AnyObject.self],
            resultType: String.self
        ) { _, _ in
            ConstExprValue("object")
        },
        ConstExprRegistration(
            name: "staticClassExistentialErasureChoice",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [Any.self],
            resultType: String.self
        ) { _, _ in
            ConstExprValue("any")
        },
        ConstExprRegistration(
            name: "makeStaticRankValueExistential",
            kind: .function,
            resultType: (any StaticRankProtocol).self
        ) { _, _ in
            let valueExistential: any StaticRankProtocol = StaticRankConformer()
            return ConstExprValue(
                valueExistential as Any,
                preservingStaticType: (any StaticRankProtocol).self,
                sourceTypeName: "any StaticRankProtocol"
            )
        },
        ConstExprRegistration(
            name: "staticValueExistentialErasureChoice",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [AnyObject.self],
            resultType: String.self
        ) { _, _ in
            ConstExprValue("object")
        },
        ConstExprRegistration(
            name: "staticValueExistentialErasureChoice",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [Any.self],
            resultType: String.self
        ) { _, _ in
            ConstExprValue("any")
        },
    ])

    let result = ConstExprRunner(registry: registry).rewrite(source: """
        let superclass = staticClassChoice(makeStaticRankLeaf())
        let erasure = staticErasureChoice(makeStaticRankLeaf())
        let classExistentialErasure = staticClassExistentialErasureChoice(makeStaticRankClassExistential())
        let valueExistentialErasure = staticValueExistentialErasureChoice(makeStaticRankValueExistential())
        """)

    #expect(result.source == """
        let superclass = "middle"
        let erasure = "object"
        let classExistentialErasure = "object"
        let valueExistentialErasure = "any"
        """)
    #expect(result.diagnostics.isEmpty)
}

@Test func evaluatorPrefersAConformingProtocolOverAny() {
    let registry = ConstExprRegistry(registrations: [
        ConstExprRegistration(
            name: "makeStaticRankConformer",
            kind: .function,
            resultType: StaticRankConformer.self
        ) { _, _ in
            ConstExprValue(StaticRankConformer())
        },
        ConstExprRegistration(
            name: "staticProtocolChoice",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [(any StaticRankProtocol).self],
            resultType: String.self
        ) { _, arguments in
            _ = try arguments[0]!.require((any StaticRankProtocol).self)
            return ConstExprValue("protocol")
        },
        ConstExprRegistration(
            name: "staticProtocolChoice",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [Any.self],
            resultType: String.self
        ) { _, arguments in
            _ = try arguments[0]!.require(Any.self)
            return ConstExprValue("any")
        },
    ])

    let result = ConstExprRunner(registry: registry).rewrite(
        source: "let value = staticProtocolChoice(makeStaticRankConformer())"
    )

    #expect(result.source == "let value = \"protocol\"")
    #expect(result.diagnostics.isEmpty)
}

@Test func evaluatorPreservesAmbiguousIntegerAndFloatingLiteralDomainsWithoutExecuting() {
    final class InvocationCounter: @unchecked Sendable {
        var count = 0
    }
    let counter = InvocationCounter()
    let registry = ConstExprRegistry(registrations: [
        ConstExprRegistration(
            name: "staticNarrowLiteralDomainChoice",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [Int8.self],
            resultType: String.self
        ) { _, _ in
            counter.count += 1
            return ConstExprValue("int8")
        },
        ConstExprRegistration(
            name: "staticNarrowLiteralDomainChoice",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [Double.self],
            resultType: String.self
        ) { _, _ in
            counter.count += 1
            return ConstExprValue("double")
        },
        ConstExprRegistration(
            name: "staticWideLiteralDomainChoice",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [Int64.self],
            resultType: String.self
        ) { _, _ in
            counter.count += 1
            return ConstExprValue("int64")
        },
        ConstExprRegistration(
            name: "staticWideLiteralDomainChoice",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [Double.self],
            resultType: String.self
        ) { _, _ in
            counter.count += 1
            return ConstExprValue("double")
        },
    ])
    let source = """
        let narrow = staticNarrowLiteralDomainChoice(1)
        let wide = staticWideLiteralDomainChoice(1)
        """

    let result = ConstExprRunner(registry: registry).rewrite(source: source)

    #expect(counter.count == 0)
    #expect(result.source == source)
    #expect(result.diagnostics.map(\.code) == [
        "ambiguous-overload",
        "ambiguous-overload",
    ])
}
