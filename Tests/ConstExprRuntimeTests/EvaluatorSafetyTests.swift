import Testing
import SwiftSyntax
import SwiftSyntaxBuilder
@testable import ConstExpr

final class ThrowingRegistrationCounter: @unchecked Sendable {
    var calls = 0
}

struct SourceExtensionShadowReceiver {}

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

struct CompoundSourceValue: ConstExprRepresentable {
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
