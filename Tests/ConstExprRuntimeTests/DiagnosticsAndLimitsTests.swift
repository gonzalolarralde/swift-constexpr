import Testing
@testable import ConstExpr

private enum ExpectedFailure: Error, CustomStringConvertible {
    case failed

    var description: String { "expected failure" }
}

private let diagnosticsRegistry = ConstExprRegistry(registrations: [
    ConstExprRegistration(
        name: "onlyInt",
        kind: .function,
        parameterLabels: [nil],
        parameterTypes: [Int.self],
        resultType: Int.self
    ) { _, arguments in
        ConstExprValue(try arguments[0]!.require(Int.self))
    },
    ConstExprRegistration(
        name: "alwaysThrows",
        kind: .function,
        resultType: Int.self
    ) { _, _ in
        throw ExpectedFailure.failed
    },
])

@Test func unknownDeclarationsAreQuietButRegisteredMismatchesAreVisible() {
    let result = ConstExprRunner(registry: diagnosticsRegistry).rewrite(source: """
        let unknown = external(true)
        let mismatch = onlyInt(true)
        """)

    #expect(result.source == """
        let unknown = external(true)
        let mismatch = onlyInt(true)
        """)
    #expect(result.diagnostics.map(\.code) == ["no-matching-overload"])
    #expect(result.diagnostics.first?.line == 2)
}

@Test func thrownRegisteredCallsRemainSourceAndProduceLocatedDiagnostics() {
    let result = ConstExprRunner(registry: diagnosticsRegistry).rewrite(
        source: "\nlet value = alwaysThrows()",
        fileName: "Throwing.swift"
    )

    #expect(result.source == "\nlet value = alwaysThrows()")
    #expect(result.diagnostics.count == 1)
    #expect(result.diagnostics[0].code == "evaluation-threw")
    #expect(result.diagnostics[0].fileName == "Throwing.swift")
    #expect(result.diagnostics[0].line == 2)
    #expect(result.diagnostics[0].message.contains("expected failure"))
}

@Test func registryCollisionsAreReportedEvenWhenTheDeclarationIsUnused() {
    let registration = ConstExprRegistration(
        name: "duplicate",
        kind: .function,
        resultType: Int.self
    ) { _, _ in ConstExprValue(1) }
    let registry = ConstExprRegistry(registrations: [registration, registration])

    let result = ConstExprRunner(registry: registry).rewrite(source: "let value = 1")

    #expect(result.source == "let value = 1")
    #expect(result.diagnostics.map(\.code) == ["registry-collision"])
    #expect(result.diagnostics[0].severity == .error)
}

@Test func parserRecoveryIsReturnedAsStructuredDiagnostics() {
    let result = ConstExprRunner(registry: .empty).rewrite(
        source: "let =",
        fileName: "Broken.swift"
    )

    #expect(result.diagnostics.contains { diagnostic in
        diagnostic.code == "parse-error"
            && diagnostic.severity == .error
            && diagnostic.fileName == "Broken.swift"
            && diagnostic.line == 1
    })
}

@Test func evaluationStepAndDepthLimitsStopWorkWithOneDiagnosticEach() {
    let stepLimited = ConstExprRunner(
        registry: .empty,
        options: .init(maximumEvaluationSteps: 2, maximumRecursionDepth: 256)
    ).rewrite(source: "let value = (((1 + 2) + 3) + 4)")

    let depthLimited = ConstExprRunner(
        registry: .empty,
        options: .init(maximumEvaluationSteps: 10_000, maximumRecursionDepth: 1)
    ).rewrite(source: "let value = (((1 + 2) + 3) + 4)")

    #expect(stepLimited.diagnostics.map(\.code) == ["maximum-node-count"])
    #expect(depthLimited.diagnostics.map(\.code) == ["maximum-depth"])
}

@Test func nonpositiveEvaluationLimitsNormalizeToOne() {
    let source = "let value = ((1 + 2) + 3)"
    let one = ConstExprRunner(
        registry: .empty,
        options: .init(maximumEvaluationSteps: 1, maximumRecursionDepth: 1)
    ).rewrite(source: source)
    let zero = ConstExprRunner(
        registry: .empty,
        options: .init(maximumEvaluationSteps: 0, maximumRecursionDepth: 0)
    ).rewrite(source: source)
    let negative = ConstExprRunner(
        registry: .empty,
        options: .init(maximumEvaluationSteps: -10, maximumRecursionDepth: -10)
    ).rewrite(source: source)

    #expect(zero == one)
    #expect(negative == one)
    #expect(one.diagnostics.map(\.code) == ["maximum-node-count"])
}

@Test func rewritingAndDiagnosticOrderingAreDeterministic() {
    let runner = ConstExprRunner(registry: diagnosticsRegistry)
    let source = """
        let first = 1 / 0
        let second = onlyInt(false)
        """

    let first = runner.rewrite(source: source, fileName: "Stable.swift")
    let second = runner.rewrite(source: source, fileName: "Stable.swift")

    #expect(first == second)
    #expect(first.diagnostics.map(\.code) == ["division-by-zero", "no-matching-overload"])
}
