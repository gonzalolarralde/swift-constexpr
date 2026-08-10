import Testing
import SwiftSyntax
import SwiftSyntaxBuilder
@testable import ConstExpr

private final class ThrowingRegistrationCounter: @unchecked Sendable {
    var calls = 0
}

private struct SourceExtensionShadowReceiver {}

@Test func evaluatorOnlyInvokesThrowingRegistrationsInsideTryExpressions() {
    let counter = ThrowingRegistrationCounter()
    let registry = ConstExprRegistry(registrations: [
        ConstExprRegistration(
            name: "manualThrowingValue",
            kind: .function,
            resultType: Int.self,
            isThrowing: true
        ) { _, _ in
            counter.calls += 1
            return ConstExprValue(7)
        }
    ])

    let result = ConstExprRunner(registry: registry).rewrite(source: """
        let missingTry = manualThrowingValue()
        let explicitTry = try manualThrowingValue()
        """)

    #expect(result.source == """
        let missingTry = manualThrowingValue()
        let explicitTry = 7
        """)
    #expect(result.diagnostics.isEmpty)
    #expect(counter.calls == 1)
}

@Test func sourceExtensionMembersSuppressPotentiallyCompetingRegistrations() {
    final class Counter: @unchecked Sendable { var methodCalls = 0 }
    let counter = Counter()
    let registry = ConstExprRegistry(registrations: [
        ConstExprRegistration(
            name: "SourceExtensionShadowReceiver",
            kind: .initializer,
            ownerType: SourceExtensionShadowReceiver.self,
            resultType: SourceExtensionShadowReceiver.self
        ) { _, _ in ConstExprValue(SourceExtensionShadowReceiver()) },
        ConstExprRegistration(
            name: "render",
            kind: .instanceMethod,
            ownerType: SourceExtensionShadowReceiver.self,
            parameterLabels: [nil],
            parameterTypes: [Int64.self],
            resultType: String.self
        ) { _, _ in
            counter.methodCalls += 1
            return ConstExprValue("registered")
        },
    ])
    let source = """
        extension SourceExtensionShadowReceiver {
            func render(_ value: Double) -> String { "source" }
        }
        let value = SourceExtensionShadowReceiver().render(1)
        """

    let result = ConstExprRunner(registry: registry).rewrite(source: source)

    #expect(result.source == source)
    #expect(result.diagnostics.isEmpty)
    #expect(counter.methodCalls == 0)
}

@Test func attributedDeclarationsRemainOpaqueToSyntaxSensitiveMacros() {
    final class Counter: @unchecked Sendable { var calls = 0 }
    let counter = Counter()
    let registry = ConstExprRegistry(registrations: [
        ConstExprRegistration(
            name: "attributeSensitiveIncrement",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [Int.self],
            resultType: Int.self
        ) { _, arguments in
            counter.calls += 1
            return ConstExprValue(try arguments[0]!.require(Int.self) + 1)
        },
    ])
    let source = """
        @SyntaxSensitive
        func attributedFunction() -> Int {
            attributeSensitiveIncrement(1)
        }
        @SyntaxSensitive
        struct AttributedType {
            func value() -> Int { attributeSensitiveIncrement(2) }
        }
        """

    let result = ConstExprRunner(registry: registry).rewrite(source: source)

    #expect(result.source == source)
    #expect(result.diagnostics.isEmpty)
    #expect(counter.calls == 0)
}

private struct CompoundSourceValue: ConstExprRepresentable {
    func constExprExpression() throws -> ExprSyntax {
        ExprSyntax(stringLiteral: "1 + 2")
    }
}

@Test func evaluatorNeverExecutesRecoveredMalformedSyntax() {
    final class Counter: @unchecked Sendable { var value = 0 }
    let counter = Counter()
    let registry = ConstExprRegistry(
        ConstExprRegistration(
            name: "increment",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [Int.self],
            resultType: Int.self
        ) { _, arguments in
            counter.value += 1
            return ConstExprValue(try arguments[0]!.require(Int.self) + 1)
        }
    )
    let source = "let value = increment(1"
    let result = ConstExprRunner(registry: registry).rewrite(source: source)

    #expect(result.source == source)
    #expect(counter.value == 0)
    #expect(result.diagnostics.contains { $0.code == "parse-error" && $0.severity == .error })
}

@Test func evaluatorNeverExecutesInvalidOrCollidingRegistrations() {
    final class Counter: @unchecked Sendable { var value = 0 }
    let counter = Counter()
    let invalid = ConstExprRegistration(
        name: "invalidConstant",
        kind: .constant,
        parameterLabels: [nil],
        parameterTypes: [Int.self],
        resultType: Int.self
    ) { _, _ in
        counter.value += 1
        return ConstExprValue(1)
    }
    let firstCollision = ConstExprRegistration(
        name: "collidingConstant",
        kind: .constant,
        resultType: Int.self,
        declarationID: "duplicate-for-evaluator-test"
    ) { _, _ in
        counter.value += 1
        return ConstExprValue(2)
    }
    let secondCollision = ConstExprRegistration(
        name: "collidingConstant",
        kind: .constant,
        resultType: Int.self,
        declarationID: "duplicate-for-evaluator-test"
    ) { _, _ in
        counter.value += 1
        return ConstExprValue(3)
    }
    let valid = ConstExprRegistration(
        name: "validValue",
        kind: .function,
        resultType: Int.self
    ) { _, _ in ConstExprValue(4) }
    let registry = ConstExprRegistry(
        registrations: [invalid, firstCollision, secondCollision, valid]
    )

    let result = ConstExprRunner(registry: registry).rewrite(source: """
        let invalid = invalidConstant
        let colliding = collidingConstant
        let valid = validValue()
        """)

    #expect(counter.value == 0)
    #expect(result.source == """
        let invalid = invalidConstant
        let colliding = collidingConstant
        let valid = 4
        """)
    #expect(result.diagnostics.contains { $0.code == "invalid-registration" })
    #expect(result.diagnostics.contains { $0.code == "registry-collision" })
}

@Test func ambiguousAndThrowingRegisteredConstantsRemainInSource() {
    enum ExpectedFailure: Error { case failed }
    final class Counts: @unchecked Sendable {
        var ambiguous = 0
        var throwing = 0
    }
    let counts = Counts()
    let registry = ConstExprRegistry(registrations: [
        ConstExprRegistration(
            name: "ambiguousConstant",
            kind: .constant,
            resultType: Int.self,
            declarationID: "ambiguous-constant-first"
        ) { _, _ in
            counts.ambiguous += 1
            return ConstExprValue(1)
        },
        ConstExprRegistration(
            name: "ambiguousConstant",
            kind: .constant,
            resultType: String.self,
            declarationID: "ambiguous-constant-second"
        ) { _, _ in
            counts.ambiguous += 1
            return ConstExprValue("one")
        },
        ConstExprRegistration(
            name: "throwingConstant",
            kind: .constant,
            resultType: Int.self
        ) { _, _ in
            counts.throwing += 1
            throw ExpectedFailure.failed
        },
    ])
    let source = """
        let ambiguous = ambiguousConstant
        let failed = throwingConstant
        """

    let result = ConstExprRunner(registry: registry).rewrite(source: source)

    #expect(result.source == source)
    #expect(counts.ambiguous == 0)
    #expect(counts.throwing == 1)
    #expect(result.diagnostics.map(\.code) == ["ambiguous-constant", "evaluation-threw"])
}

@Test func evaluatorNeverExecutesWhenOperatorFoldingFails() {
    final class Counter: @unchecked Sendable { var value = 0 }
    let counter = Counter()
    let registry = ConstExprRegistry(
        ConstExprRegistration(
            name: "increment",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [Int.self],
            resultType: Int.self
        ) { _, arguments in
            counter.value += 1
            return ConstExprValue(try arguments[0]!.require(Int.self) + 1)
        }
    )
    let source = "let value = increment(1) <=> 2"
    let result = ConstExprRunner(registry: registry).rewrite(source: source)

    #expect(result.source == source)
    #expect(counter.value == 0)
    #expect(result.diagnostics.map(\.code) == ["operator-error"])
}

@Test func evaluatorTreatsAttributeArgumentsAsSyntax() {
    final class Counter: @unchecked Sendable { var value = 0 }
    let counter = Counter()
    let registry = ConstExprRegistry(
        ConstExprRegistration(
            name: "increment",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [Int.self],
            resultType: Int.self
        ) { _, arguments in
            counter.value += 1
            return ConstExprValue(try arguments[0]!.require(Int.self) + 1)
        }
    )
    let source = "@Demo(increment(1)) struct Example {}"
    let result = ConstExprRunner(registry: registry).rewrite(source: source)

    #expect(result.source == source)
    #expect(counter.value == 0)
}

@Test func evaluatorTreatsEnumCaseExpressionsAsOpaqueTypeContexts() {
    let source = """
        enum Byte: UInt8 {
            case wrapped = 255 &+ 1
        }
        """

    let result = ConstExprRunner(registry: .empty).rewrite(source: source)

    #expect(result.source == source)
    #expect(result.diagnostics.isEmpty)
}

@Test func evaluatorUsesEverySyntacticallyKnownNumericContext() {
    let result = ConstExprRunner(registry: .empty).rewrite(source: """
        func explicit() -> UInt8 { return 255 &+ 1 }
        func implicit() -> UInt8 { 255 &+ 1 }
        func defaulted(_ value: UInt8 = 255 &+ 1) {}
        var assigned: UInt8 = 0
        assigned = 255 &+ 1
        let casted = (255 &+ 1) as UInt8
        """)

    #expect(result.source == """
        func explicit() -> UInt8 { return (0) as Swift.UInt8 }
        func implicit() -> UInt8 { (0) as Swift.UInt8 }
        func defaulted(_ value: UInt8 = (0) as Swift.UInt8) {}
        var assigned: UInt8 = (0) as Swift.UInt8
        assigned = ((0) as Swift.UInt8)
        let casted = (0) as Swift.UInt8
        """)
    #expect(result.diagnostics.isEmpty)
}

@Test func evaluatorUsesTypedSiblingsBeforeRewritingPolymorphicOperators() {
    let result = ConstExprRunner(registry: .empty).rewrite(source: """
        let typed: UInt8 = external()
        let comparison = (255 &+ 1) == typed
        let sum = typed + (255 &+ 1)
        let collection = [255 &+ 1, UInt8(0)]
        let conditional = true ? 255 &+ 1 : UInt8(0)
        """)

    #expect(result.source == """
        let typed: UInt8 = external()
        let comparison = ((0) as Swift.UInt8) == typed
        let sum = typed + ((0) as Swift.UInt8)
        let collection = [(0) as Swift.UInt8, (0) as Swift.UInt8]
        let conditional = (0) as Swift.UInt8
        """)
    #expect(result.diagnostics.isEmpty)
}

@Test func evaluatorNeverReexecutesACallWhileInferringCollectionContext() {
    final class Counter: @unchecked Sendable { var value = 0 }
    let counter = Counter()
    let registry = ConstExprRegistry(
        ConstExprRegistration(
            name: "counted",
            kind: .function,
            resultType: Int.self
        ) { _, _ in
            counter.value += 1
            return ConstExprValue(1)
        }
    )

    let result = ConstExprRunner(registry: registry).rewrite(
        source: "let values = [counted() + 1, Int64(2)]"
    )

    #expect(counter.value == 1)
    #expect(result.source.contains("counted() + 1"))
}

@Test func evaluatorNeverExecutesRegisteredVariableInitializersInConditionalBodies() {
    final class Counter: @unchecked Sendable { var value = 0 }
    let counter = Counter()
    let registry = ConstExprRegistry(
        ConstExprRegistration(
            name: "conditionalValue",
            kind: .function,
            resultType: Int.self
        ) { _, _ in
            counter.value += 1
            return ConstExprValue(1)
        }
    )
    let source = """
        if condition {
            let value = conditionalValue()
            unknown(value)
        }
        switch input {
        case 1:
            let value = conditionalValue()
            unknown(value)
        default:
            break
        }
        """

    let result = ConstExprRunner(registry: registry).rewrite(source: source)

    #expect(counter.value == 0)
    #expect(result.source == source)
}

@Test func evaluatorDoesNotLeakSubscriptReturnContextIntoLaterCode() {
    let result = ConstExprRunner(registry: .empty).rewrite(source: """
        struct Values {
            subscript(index: Int) -> UInt8 { 255 &+ 1 }
            subscript(explicit index: Int) -> Int64 { return 1 + 2 }
            func next() -> Int64 { 1 + 2 }
        }
        unknown(255 &+ 1)
        """)

    #expect(result.source == """
        struct Values {
            subscript(index: Int) -> UInt8 { (0) as Swift.UInt8 }
            subscript(explicit index: Int) -> Int64 { return (3) as Swift.Int64 }
            func next() -> Int64 { (3) as Swift.Int64 }
        }
        unknown(255 &+ 1)
        """)
    #expect(result.diagnostics.isEmpty)
}

@Test func evaluatorUsesTheOptionalWrappedTypeForNilCoalescing() {
    let result = ConstExprRunner(registry: .empty).rewrite(source: """
        let missing: UInt8? = nil
        let present: UInt8? = 7
        let fromMissing = missing ?? (255 &+ 1)
        let fromPresent = present ?? (1 / 0)
        """)

    #expect(result.source == """
        let missing: UInt8? = nil as UInt8?
        let present: UInt8? = ((7) as Swift.UInt8) as UInt8?
        let fromMissing = (0) as Swift.UInt8
        let fromPresent = (7) as Swift.UInt8
        """)
    #expect(!result.diagnostics.contains { $0.code == "division-by-zero" })
}

@Test func evaluatorFoldsKnownForceUnwrapsAndDiagnosesNil() {
    let result = ConstExprRunner(registry: .empty).rewrite(source: """
        let present: Int? = 4
        let value = present!
        let absent: Int? = nil
        let trap = absent!
        """)

    #expect(result.source == """
        let present: Int? = (4) as Int?
        let value = 4
        let absent: Int? = nil as Int?
        let trap = (nil as Int?)!
        """)
    #expect(result.diagnostics.map(\.code) == ["forced-unwrap-of-nil"])
}

@Test func evaluatorDoesNotPropagateAnUnresolvedExplicitAnnotation() {
    let result = ConstExprRunner(registry: .empty).rewrite(source: """
        typealias MyInt = Int64
        let value: MyInt = (1)
        unknown(value)
        """)

    #expect(result.source == """
        typealias MyInt = Int64
        let value: MyInt = (1)
        unknown(value)
        """)
}

@Test func evaluatorPreservesContextDependentStructuralOperations() {
    let result = ConstExprRunner(registry: .empty).rewrite(source: """
        let arrays = [1] == [1.0]
        let dictionaries = [1: "x"] == [1.0: "x"]
        let heterogeneousArray = [1, 2.0][0]
        let heterogeneousDictionary = [1: 1, 2: 2.0][1]
        """)

    #expect(result.source == """
        let arrays = [1] == [1.0]
        let dictionaries = [1: "x"] == [1.0: "x"]
        let heterogeneousArray = [1, 2.0][0]
        let heterogeneousDictionary = [1: 1, 2: 2.0][1]
        """)
    #expect(result.diagnostics.isEmpty)
}

@Test func evaluatorDiagnosesDuplicateDictionaryKeysWithoutProducingAValue() {
    let result = ConstExprRunner(registry: .empty).rewrite(
        source: "let values = [\"x\": 1, \"x\": 2]"
    )

    #expect(result.source == "let values = [\"x\": 1, \"x\": 2]")
    #expect(result.diagnostics.map(\.code) == ["duplicate-dictionary-key"])
}

@Test func evaluatorTreatsConditionalCompilationBindingsAsOpaque() {
    let result = ConstExprRunner(registry: .empty).rewrite(source: """
        #if FIRST_CONFIGURATION
        let conditional = 1
        #else
        let conditional = 2
        #endif
        unknown(conditional)
        """)

    #expect(result.source == """
        #if FIRST_CONFIGURATION
        let conditional = 1
        #else
        let conditional = 2
        #endif
        unknown(conditional)
        """)
}

@Test func evaluatorScopesInitializerSubscriptAndAccessorParameters() {
    let registry = ConstExprRegistry(
        ConstExprRegistration(
            name: "exampleAnswer",
            kind: .constant,
            resultType: Int.self
        ) { _, _ in ConstExprValue(42) }
    )
    let source = """
        struct Example {
            init(exampleAnswer: Int) { consume(exampleAnswer) }
            subscript(exampleAnswer: Int) -> Int { return exampleAnswer }
            var value: Int {
                get { 0 }
                set { consume(newValue) }
            }
            var observed = 0 {
                willSet { consume(newValue) }
                didSet { consume(oldValue) }
            }
        }
        """
    let result = ConstExprRunner(registry: registry).rewrite(source: source)

    #expect(result.source == source)
}

@Test func evaluatorParenthesizesCompoundCustomRepresentationsWhenEmbedded() {
    let registry = ConstExprRegistry(
        ConstExprRegistration(
            name: "compoundSource",
            kind: .function,
            resultType: CompoundSourceValue.self
        ) { _, _ in ConstExprValue(CompoundSourceValue()) }
    )
    let result = ConstExprRunner(registry: registry).rewrite(
        source: "let value = compoundSource() * external"
    )

    #expect(result.source == "let value = (1 + 2) * external")
}
