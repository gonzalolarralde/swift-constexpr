import Testing
@testable import ConstExpr

class DifferentialBase {}
final class DifferentialDerived: DifferentialBase {}
struct DifferentialSubscriptBox {}
struct Foo {}

enum MySwift {
    struct Value {}
}

final class DifferentialCounter: @unchecked Sendable {
    var factory = 0
    var fallback = 0
    var baseOverload = 0
    var derivedOverload = 0
    var invalid = 0
}

@Test func knownSomeNilCoalescingPreservesItsSwiftJoinWithoutInvokingTheFallback() {
    let counter = DifferentialCounter()
    let registry = ConstExprRegistry(registrations: [
        ConstExprRegistration(
            name: "makeDifferentialDerived",
            kind: .function,
            resultType: DifferentialDerived?.self
        ) { _, _ in
            counter.factory += 1
            return ConstExprValue(Optional.some(DifferentialDerived()))
        },
        ConstExprRegistration(
            name: "makeDifferentialBase",
            kind: .function,
            resultType: DifferentialBase.self
        ) { _, _ in
            counter.fallback += 1
            return ConstExprValue(DifferentialBase())
        },
        ConstExprRegistration(
            name: "differentialChoice",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [DifferentialBase.self],
            resultType: String.self,
            declarationID: "differential-choice-base"
        ) { _, _ in
            counter.baseOverload += 1
            return ConstExprValue("base")
        },
        ConstExprRegistration(
            name: "differentialChoice",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [DifferentialDerived.self],
            resultType: String.self,
            declarationID: "differential-choice-derived"
        ) { _, _ in
            counter.derivedOverload += 1
            return ConstExprValue("derived")
        },
    ])

    let result = ConstExprRunner(registry: registry).rewrite(
        source: "let value = differentialChoice(makeDifferentialDerived() ?? makeDifferentialBase())"
    )

    #expect(result.source == "let value = \"base\"")
    #expect(result.diagnostics.isEmpty)
    #expect(counter.factory == 1)
    #expect(counter.fallback == 0)
    #expect(counter.baseOverload == 1)
    #expect(counter.derivedOverload == 0)
}

@Test func ternaryEvaluationPreservesItsSwiftJoinAndBranchLaziness() {
    let counter = DifferentialCounter()
    let registry = ConstExprRegistry(registrations: [
        ConstExprRegistration(
            name: "makeTernaryDerived",
            kind: .function,
            resultType: DifferentialDerived.self
        ) { _, _ in
            counter.factory += 1
            return ConstExprValue(DifferentialDerived())
        },
        ConstExprRegistration(
            name: "makeTernaryBase",
            kind: .function,
            resultType: DifferentialBase.self
        ) { _, _ in
            counter.fallback += 1
            return ConstExprValue(DifferentialBase())
        },
        ConstExprRegistration(
            name: "ternaryDifferentialChoice",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [DifferentialBase.self],
            resultType: String.self,
            declarationID: "ternary-differential-choice-base"
        ) { _, _ in
            counter.baseOverload += 1
            return ConstExprValue("base")
        },
        ConstExprRegistration(
            name: "ternaryDifferentialChoice",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [DifferentialDerived.self],
            resultType: String.self,
            declarationID: "ternary-differential-choice-derived"
        ) { _, _ in
            counter.derivedOverload += 1
            return ConstExprValue("derived")
        },
    ])

    let result = ConstExprRunner(registry: registry).rewrite(source: """
        let selectedDerived = ternaryDifferentialChoice(
            true ? makeTernaryDerived() : makeTernaryBase()
        )
        let selectedBase = ternaryDifferentialChoice(
            false ? makeTernaryDerived() : makeTernaryBase()
        )
        """)

    #expect(result.source == """
        let selectedDerived = "base"
        let selectedBase = "base"
        """)
    #expect(result.diagnostics.isEmpty)
    #expect(counter.factory == 1)
    #expect(counter.fallback == 1)
    #expect(counter.baseOverload == 2)
    #expect(counter.derivedOverload == 0)
}

@Test func explicitlyErasedCollectionBindingsNeverNarrowFromTheirPayloads() {
    let counter = DifferentialCounter()
    let registry = ConstExprRegistry(
        ConstExprRegistration(
            name: "acceptDifferentialInts",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [[Int].self],
            resultType: String.self
        ) { _, _ in
            counter.invalid += 1
            return ConstExprValue("invalidly narrowed")
        }
    )

    let result = ConstExprRunner(registry: registry).rewrite(source: """
        let populated: [Any] = [1]
        let empty: [Any] = []
        let populatedResult = acceptDifferentialInts(populated)
        let emptyResult = acceptDifferentialInts(empty)
        """)

    #expect(counter.invalid == 0)
    #expect(result.source.contains("acceptDifferentialInts(([1]) as [Any])"))
    #expect(result.source.contains("acceptDifferentialInts(([]) as [Any])"))
    #expect(!result.source.contains("invalidly narrowed"))
    #expect(result.diagnostics.map(\.code) == [
        "no-matching-overload",
        "no-matching-overload",
    ])
}

func hiddenContextRegistry(counter: DifferentialCounter) -> ConstExprRegistry {
    ConstExprRegistry(
        ConstExprRegistration(
            name: "differentialByte",
            kind: .function,
            resultType: UInt8.self
        ) { _, _ in
            counter.invalid += 1
            return ConstExprValue(UInt8(1))
        }
    )
}

@Test func implicitClosureResultContextRemainsOpaque() {
    let counter = DifferentialCounter()
    let source = """
        let folded: () -> UInt8 = { 255 &+ 1 }
        let invoked: () -> UInt8 = { differentialByte() }
        """

    let result = ConstExprRunner(registry: hiddenContextRegistry(counter: counter))
        .rewrite(source: source)

    #expect(result.source == source)
    #expect(result.diagnostics.isEmpty)
    #expect(counter.invalid == 0)
}
@Test func propertyWrapperInitializerContextRemainsOpaque() {
    let counter = DifferentialCounter()
    let source = """
        @propertyWrapper
        struct DifferentialByteWrapper {
            var wrappedValue: UInt8
        }
        struct DifferentialWrappedValues {
            @DifferentialByteWrapper var folded = 255 &+ 1
            @DifferentialByteWrapper var invoked = differentialByte()
        }
        """

    let result = ConstExprRunner(registry: hiddenContextRegistry(counter: counter))
        .rewrite(source: source)

    #expect(result.source == source)
    #expect(result.diagnostics.isEmpty)
    #expect(counter.invalid == 0)
}

@Test func resultBuilderExpressionContextRemainsOpaque() {
    let counter = DifferentialCounter()
    let source = """
        @resultBuilder
        enum DifferentialByteBuilder {
            static func buildExpression(_ value: UInt8) -> UInt8 { value }
            static func buildBlock(_ value: UInt8) -> UInt8 { value }
        }
        func buildDifferentialByte(
            @DifferentialByteBuilder _ body: () -> UInt8
        ) -> UInt8 {
            body()
        }
        let folded = buildDifferentialByte { 255 &+ 1 }
        let invoked = buildDifferentialByte { differentialByte() }
        """

    let result = ConstExprRunner(registry: hiddenContextRegistry(counter: counter))
        .rewrite(source: source)

    #expect(result.source == source)
    #expect(result.diagnostics.isEmpty)
    #expect(counter.invalid == 0)
}

@Test func subjectTypedPatternExpressionsRemainOpaque() {
    let source = """
        let byte: UInt8 = 0
        switch byte {
        case 255 &+ 1:
            break
        default:
            break
        }
        if case 255 &+ 1 = byte {
            consume(byte)
        }
        """

    let result = ConstExprRunner(registry: .empty).rewrite(source: source)

    #expect(result.source.contains("case 255 &+ 1:"))
    #expect(result.source.contains("if case 255 &+ 1 = byte"))
    #expect(!result.source.contains("case 256:"))
    #expect(!result.source.contains("if case 256 = byte"))
    #expect(result.diagnostics.isEmpty)
}

@Test func customStringInterpolationArgumentContextRemainsOpaque() {
    let counter = DifferentialCounter()
    let source = #"""
        struct DifferentialByteString: ExpressibleByStringInterpolation {
            struct StringInterpolation: StringInterpolationProtocol {
                init(literalCapacity: Int, interpolationCount: Int) {}
                mutating func appendLiteral(_ literal: String) {}
                mutating func appendInterpolation(_ value: UInt8) {}
            }
            init(stringLiteral value: String) {}
            init(stringInterpolation: StringInterpolation) {}
        }
        let folded: DifferentialByteString = "\(255 &+ 1)"
        let invoked: DifferentialByteString = "\(differentialByte())"
        """#

    let result = ConstExprRunner(registry: hiddenContextRegistry(counter: counter))
        .rewrite(source: source)

    #expect(result.source == source)
    #expect(result.diagnostics.isEmpty)
    #expect(counter.invalid == 0)
}

@Test func explicitBindingAndCastUpcastsPreserveAUsableConstantValue() {
    let counter = DifferentialCounter()
    let registry = ConstExprRegistry(registrations: [
        ConstExprRegistration(
            name: "makeDifferentialConcrete",
            kind: .function,
            resultType: DifferentialDerived.self
        ) { _, _ in
            counter.factory += 1
            return ConstExprValue(DifferentialDerived())
        },
        ConstExprRegistration(
            name: "acceptDifferentialBase",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [DifferentialBase.self],
            resultType: String.self
        ) { _, arguments in
            counter.baseOverload += 1
            _ = try arguments[0]!.require(DifferentialBase.self)
            return ConstExprValue("base")
        },
    ])

    let result = ConstExprRunner(registry: registry).rewrite(source: """
        let annotated: DifferentialBase = makeDifferentialConcrete()
        let throughBinding = acceptDifferentialBase(annotated)
        let throughCast = acceptDifferentialBase(makeDifferentialConcrete() as DifferentialBase)
        """)

    #expect(result.source == """
        let annotated: DifferentialBase = makeDifferentialConcrete()
        let throughBinding = "base"
        let throughCast = "base"
        """)
    #expect(result.diagnostics.isEmpty)
    #expect(counter.baseOverload == 2)
}

@Test func registeredBaseMemberIsAvailableOnAStaticallyDerivedReceiver() {
    let counter = DifferentialCounter()
    let registry = ConstExprRegistry(registrations: [
        ConstExprRegistration(
            name: "makeDifferentialConcrete",
            kind: .function,
            resultType: DifferentialDerived.self
        ) { _, _ in
            counter.factory += 1
            return ConstExprValue(DifferentialDerived())
        },
        ConstExprRegistration(
            name: "inheritedDifferentialValue",
            kind: .instanceMethod,
            ownerType: DifferentialBase.self,
            resultType: String.self
        ) { receiver, _ in
            counter.baseOverload += 1
            _ = try receiver!.require(DifferentialBase.self)
            return ConstExprValue("inherited")
        },
    ])

    let result = ConstExprRunner(registry: registry).rewrite(
        source: "let value = makeDifferentialConcrete().inheritedDifferentialValue()"
    )

    #expect(result.source == "let value = \"inherited\"")
    #expect(result.diagnostics.isEmpty)
    #expect(counter.factory == 1)
    #expect(counter.baseOverload == 1)
}

@Test func unqualifiedBuiltinTypeShadowsRemainOpaqueToEvaluation() {
    let counter = DifferentialCounter()
    let registry = ConstExprRegistry(
        ConstExprRegistration(
            name: "+++",
            kind: .infixOperator,
            parameterLabels: [nil, nil],
            parameterTypes: [Swift.Int.self, Swift.Int.self],
            resultType: Swift.Int.self,
            precedenceGroup: "AdditionPrecedence"
        ) { _, _ in
            counter.invalid += 1
            return ConstExprValue(Swift.Int(999))
        }
    )
    let source = """
        infix operator +++: AdditionPrecedence
        struct Int: ExpressibleByIntegerLiteral {
            typealias IntegerLiteralType = Swift.Int
            let rawValue: Swift.Int
            init(integerLiteral value: Swift.Int) {
                rawValue = value
            }
        }
        func +++ (lhs: Int, rhs: Int) -> Int { lhs }
        func consumeShadow<T>(_ value: T) {}
        let shadowed: Int = 1
        consumeShadow(shadowed +++ 1)
        """

    let result = ConstExprRunner(registry: registry).rewrite(source: source)

    #expect(result.source == source)
    #expect(result.diagnostics.isEmpty)
    #expect(counter.invalid == 0)
}
