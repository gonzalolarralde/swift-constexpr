import Testing
@testable import ConstExpr

@Test func evaluatorSynthesizesMissingPrefixInfixAndPostfixDeclarations() {
    let registry = ConstExprRegistry(registrations: [
        .prefixOperator("~~~", operand: Int.self, result: Int.self) { -$0 },
        .infixOperator(
            "<*>",
            left: Int.self,
            right: Int.self,
            result: Int.self,
            precedenceGroup: "MultiplicationPrecedence",
            associativity: .left
        ) { $0 * $1 },
        .infixOperator(
            "<*>",
            left: Double.self,
            right: Double.self,
            result: Double.self,
            precedenceGroup: "MultiplicationPrecedence",
            associativity: .left
        ) { $0 * $1 },
        .postfixOperator("^^^", operand: Int.self, result: Int.self) { $0 * 2 },
    ])

    let result = ConstExprRunner(registry: registry).rewrite(source: """
        let prefix = ~~~5
        let infix = 2 <*> 3 + 4
        let postfix = 5^^^ + 1
        """)

    #expect(result.source == """
        let prefix = -5
        let infix = 10
        let postfix = 11
        """)
    #expect(result.diagnostics.isEmpty)
}

@Test func evaluatorUsesSynthesizedPrecedenceGroupAssociativity() {
    let registry = ConstExprRegistry(
        .infixOperator(
            "**",
            left: Int.self,
            right: Int.self,
            result: Int.self,
            precedenceGroup: "AssignmentPrecedence",
            associativity: .right
        ) { base, exponent in
            (0..<exponent).reduce(1) { value, _ in value * base }
        }
    )

    let result = ConstExprRunner(registry: registry).rewrite(
        source: "let value = 2 ** 3 ** 2"
    )

    #expect(result.source == "let value = 512")
    #expect(result.diagnostics.isEmpty)
}

@Test func evaluatorPrefersAVisibleSourceOperatorDeclaration() {
    let integer = ConstExprRegistration.infixOperator(
        "<->",
        left: Int.self,
        right: Int.self,
        result: Int.self,
        precedenceGroup: "AdditionPrecedence",
        associativity: .left
    ) { $0 - $1 }
    let floatingPoint = ConstExprRegistration.infixOperator(
        "<->",
        left: Double.self,
        right: Double.self,
        result: Double.self,
        precedenceGroup: "AdditionPrecedence",
        associativity: .left
    ) { $0 - $1 }
    let registry = ConstExprRegistry(registrations: [integer, floatingPoint])

    let result = ConstExprRunner(registry: registry).rewrite(source: """
        infix operator <->: AdditionPrecedence
        let value = 2 <-> 3 * 4
        """)

    #expect(result.source == """
        infix operator <->: AdditionPrecedence
        let value = -10
        """)
    #expect(result.diagnostics.isEmpty)
}

@Test func evaluatorRejectsConflictingSynthesizedOperatorMetadata() {
    final class Counter: @unchecked Sendable { var value = 0 }
    let counter = Counter()
    let addition = ConstExprRegistration.infixOperator(
        "<~>",
        left: Int.self,
        right: Int.self,
        result: Int.self,
        precedenceGroup: "AdditionPrecedence",
        associativity: .left
    ) { lhs, rhs in
        counter.value += 1
        return lhs + rhs
    }
    let multiplication = ConstExprRegistration.infixOperator(
        "<~>",
        left: Double.self,
        right: Double.self,
        result: Double.self,
        precedenceGroup: "MultiplicationPrecedence",
        associativity: .right
    ) { lhs, rhs in
        counter.value += 1
        return lhs * rhs
    }
    let source = "let value = 1 <~> 2"

    let result = ConstExprRunner(
        registry: ConstExprRegistry(registrations: [addition, multiplication])
    ).rewrite(source: source)

    #expect(counter.value == 0)
    #expect(result.source == source)
    #expect(result.diagnostics.contains {
        $0.code == "operator-registration-conflict"
    })
    #expect(result.diagnostics.contains { $0.code == "operator-error" })
}

@Test func evaluatorNeverSynthesizesInvalidOrCollidingOperatorRegistrations() {
    final class Counter: @unchecked Sendable { var value = 0 }
    let counter = Counter()
    let invalid = ConstExprRegistration(
        name: "<!>",
        kind: .infixOperator,
        parameterLabels: [nil],
        parameterTypes: [Int.self],
        resultType: Int.self
    ) { _, _ in
        counter.value += 1
        return ConstExprValue(1)
    }
    let collisionA = ConstExprRegistration.prefixOperator(
        "|+|",
        operand: Int.self,
        result: Int.self
    ) { value in
        counter.value += 1
        return value
    }
    let collisionB = ConstExprRegistration(
        name: collisionA.name,
        kind: collisionA.kind,
        parameterLabels: collisionA.parameterLabels,
        parameterTypes: collisionA.parameterTypes,
        resultType: collisionA.resultType,
        declarationID: collisionA.declarationID
    ) { _, _ in
        counter.value += 1
        return ConstExprValue(2)
    }
    let valid = ConstExprRegistration(
        name: "validOperatorControl",
        kind: .function,
        resultType: Int.self
    ) { _, _ in ConstExprValue(3) }

    let result = ConstExprRunner(
        registry: ConstExprRegistry(
            registrations: [invalid, collisionA, collisionB, valid]
        )
    ).rewrite(source: "let value = validOperatorControl()")

    #expect(counter.value == 0)
    #expect(result.source == "let value = 3")
    #expect(result.diagnostics.contains { $0.code == "invalid-registration" })
    #expect(result.diagnostics.contains { $0.code == "registry-collision" })
    #expect(!result.diagnostics.contains { $0.code == "operator-registration-error" })
}

@Test func evaluatorDoesNotRedeclareOperatorsAlreadyInTheStandardTable() {
    let registry = ConstExprRegistry(
        .infixOperator(
            "+",
            left: String.self,
            right: String.self,
            result: String.self,
            precedenceGroup: "AdditionPrecedence",
            associativity: .left
        ) { $0 + $1 }
    )

    let result = ConstExprRunner(registry: registry).rewrite(
        source: "let value = 1 + 2"
    )

    #expect(result.source == "let value = 3")
    #expect(result.diagnostics.isEmpty)
}

@Test func installedStandardOperatorRegistrationsSkipSynthesisPreparation() {
    let registry = ConstExprRegistry(
        .infixOperator(
            "+",
            left: Int.self,
            right: Int.self,
            result: Int.self,
            precedenceGroup: "AdditionPrecedence",
            associativity: .left
        ) { $0 + $1 }
    )
    let recorder = ConstExprRegisteredOperatorPreparationProbe.Recorder()

    let result = ConstExprRegisteredOperatorPreparationProbe.$recorder.withValue(recorder) {
        ConstExprRunner(registry: registry).rewrite(source: "let value = 1 + 2")
    }

    #expect(result.source == "let value = 3")
    #expect(result.diagnostics.isEmpty)
    #expect(recorder.events.isEmpty)
}

@Test func unknownCustomOperatorStillRunsSynthesisPreparationOncePerKey() {
    let registry = ConstExprRegistry(
        .infixOperator(
            "<+>",
            left: Int.self,
            right: Int.self,
            result: Int.self,
            precedenceGroup: "AdditionPrecedence",
            associativity: .left
        ) { $0 + $1 }
    )
    let recorder = ConstExprRegisteredOperatorPreparationProbe.Recorder()

    let result = ConstExprRegisteredOperatorPreparationProbe.$recorder.withValue(recorder) {
        ConstExprRunner(registry: registry).rewrite(source: "let value = 1 <+> 2")
    }

    #expect(result.source == "let value = 3")
    #expect(result.diagnostics.isEmpty)
    #expect(recorder.events == [
        .sourceOperatorCollection,
        .precedenceTableSerializationAndParse,
        .syntheticDeclarationParse,
    ])
}

@Test func evaluatorRejectsOperatorNamesThatFormMoreThanOneDeclaration() {
    let injectedName = "<+>\ninfix operator <*>"
    let registration = ConstExprRegistration.infixOperator(
        injectedName,
        left: Int.self,
        right: Int.self,
        result: Int.self,
        precedenceGroup: "AdditionPrecedence"
    ) { $0 + $1 }

    let source = "let value = 1 <*> 2"
    let result = ConstExprRunner(registry: .init(registration)).rewrite(source: source)

    #expect(result.source == source)
    #expect(result.diagnostics.contains { $0.code == "operator-registration-error" })
}
