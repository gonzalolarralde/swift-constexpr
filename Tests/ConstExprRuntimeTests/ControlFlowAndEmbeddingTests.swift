import Testing
@testable import ConstExpr

@Test func ternaryFoldingPreservesOptionalResultInference() {
    let runner = ConstExprRunner(registry: .empty)
    let present = runner.rewrite(source: "let value = true ? 1 : nil")
    let absent = runner.rewrite(source: "let value = false ? 1 : nil")

    #expect(present.source == "let value = (1) as Int?")
    #expect(absent.source == "let value = nil as Int?")
}

@Test func unknownTernaryConditionsNeverExecuteEitherRegisteredBranch() {
    final class Counts: @unchecked Sendable {
        var thenBranch = 0
        var elseBranch = 0
    }
    let counts = Counts()
    let registry = ConstExprRegistry(registrations: [
        ConstExprRegistration(
            name: "thenValue",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [Int.self],
            resultType: Int.self
        ) { _, arguments in
            counts.thenBranch += 1
            return ConstExprValue(try arguments[0]!.require(Int.self))
        },
        ConstExprRegistration(
            name: "elseValue",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [Int.self],
            resultType: Int.self
        ) { _, arguments in
            counts.elseBranch += 1
            return ConstExprValue(try arguments[0]!.require(Int.self))
        },
    ])

    let result = ConstExprRunner(registry: registry).rewrite(
        source: "let value = externalFlag ? thenValue(1 + 2) : elseValue(2 * 3)"
    )

    #expect(
        result.source
            == "let value = externalFlag ? thenValue(3) : elseValue(6)"
    )
    #expect(counts.thenBranch == 0)
    #expect(counts.elseBranch == 0)
    #expect(result.diagnostics.isEmpty)
}

@Test func unsupportedIfExpressionNeverInvokesAnUnselectedRegisteredBranch() {
    final class Counts: @unchecked Sendable {
        var selected = 0
        var unselected = 0
    }
    let counts = Counts()
    let registry = ConstExprRegistry(registrations: [
        ConstExprRegistration(
            name: "selected",
            kind: .function,
            resultType: Int.self
        ) { _, _ in
            counts.selected += 1
            return ConstExprValue(1)
        },
        ConstExprRegistration(
            name: "unselected",
            kind: .function,
            resultType: Int.self
        ) { _, _ in
            counts.unselected += 1
            return ConstExprValue(2)
        },
    ])

    _ = ConstExprRunner(registry: registry).rewrite(
        source: "let value = if true { selected() } else { unselected() }"
    )

    #expect(counts.unselected == 0)
    #expect(counts.selected == 0 || counts.selected == 1)
}

@Test func conditionalPatternBindingsNeverResolveToSameNamedOuterConstants() {
    let result = ConstExprRunner(registry: .empty).rewrite(source: """
        let value = 1
        if let value = optional {
            unknown(value)
        }
        while let value = next() {
            unknown(value)
        }
        switch optional {
        case .some(let value):
            unknown(value)
        default:
            break
        }
        unknown(value)
        """)

    #expect(result.source == """
        let value = 1
        if let value = optional {
            unknown(value)
        }
        while let value = next() {
            unknown(value)
        }
        switch optional {
        case .some(let value):
            unknown(value)
        default:
            break
        }
        unknown(1)
        """)
}

@Test func guardBindingsConservativelyShadowOuterConstantsAfterTheGuard() {
    let result = ConstExprRunner(registry: .empty).rewrite(source: """
        let value = 1
        func consume() {
            guard let value = optional else { return }
            unknown(value)
        }
        unknown(value)
        """)

    #expect(result.source == """
        let value = 1
        func consume() {
            guard let value = optional else { return }
            unknown(value)
        }
        unknown(1)
        """)
}

@Test func dictionarySubscriptsAlwaysMaterializeAnOptionalValueType() {
    let runner = ConstExprRunner(registry: .empty)
    let result = runner.rewrite(source: """
        let present = ["a": 1]["a"]
        let absent = ["a": 1]["b"]
        """)

    #expect(result.source == """
        let present = (1) as Int?
        let absent = nil as Int?
        """)
}

@Test func unknownCallsStillRewriteRegisteredCallsInsideTrailingClosures() {
    let registry = ConstExprRegistry(registrations: [
        ConstExprRegistration(
            name: "increment",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [Int.self],
            resultType: Int.self
        ) { _, arguments in
            ConstExprValue(try arguments[0]!.require(Int.self) + 1)
        },
    ])

    let result = ConstExprRunner(registry: registry).rewrite(source: """
        unknown {
            increment(1)
        }
        unknown { value in
            increment(value)
        }
        """)

    #expect(result.source == """
        unknown {
            2
        }
        unknown { value in
            increment(value)
        }
        """)
}

@Test func unknownTrailingClosureResultContextsDoNotDefaultPolymorphicOperators() {
    let registry = ConstExprRegistry(registrations: [
        ConstExprRegistration(
            name: "increment",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [Int.self],
            resultType: Int.self
        ) { _, arguments in
            ConstExprValue(try arguments[0]!.require(Int.self) + 1)
        },
    ])
    let source = """
        let contextual = ImportedBuilder { 255 &+ 1 }
        let labeled = importedConsume(transform: { 255 &+ 1 })
        let typePreserving = ImportedBuilder { increment(1) }
        """

    let result = ConstExprRunner(registry: registry).rewrite(source: source)

    #expect(result.source == """
        let contextual = ImportedBuilder { 255 &+ 1 }
        let labeled = importedConsume(transform: { 255 &+ 1 })
        let typePreserving = ImportedBuilder { 2 }
        """)
    #expect(result.diagnostics.isEmpty)
}
