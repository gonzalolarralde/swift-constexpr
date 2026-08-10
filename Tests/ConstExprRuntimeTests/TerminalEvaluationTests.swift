import Testing
import SwiftSyntax
import SwiftSyntaxBuilder
@testable import ConstExpr

private struct TerminalBox: Equatable {
    let value: Int
}

private final class TerminalRenderCounter: @unchecked Sendable {
    var calls = 0
}

private struct TerminalRenderProbe: ConstExprRepresentable {
    let counter: TerminalRenderCounter

    func constExprExpression() throws -> ExprSyntax {
        counter.calls += 1
        return ExprSyntax(stringLiteral: "123")
    }
}

private func terminalRegistry() -> ConstExprRegistry {
    ConstExprRegistry(registrations: [
        ConstExprRegistration(
            name: "TerminalBox",
            kind: .initializer,
            ownerType: TerminalBox.self,
            parameterLabels: ["value"],
            parameterTypes: [Int.self],
            resultType: TerminalBox.self
        ) { _, arguments in
            ConstExprValue(TerminalBox(value: try arguments[0]!.require(Int.self)))
        },
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
}

@Test func terminalEvaluationReturnsTypedOpaqueGlobalWithoutReparsingOutput() {
    let result = ConstExprRunner(registry: terminalRegistry()).evaluate(
        source: "let package = TerminalBox(value: increment(40))",
        binding: "package",
        as: TerminalBox.self,
        policy: .certifying
    )

    #expect(result == .success(TerminalBox(value: 41)))
}

@Test func untypedTerminalEvaluationCanRenderAResolvedBinding() throws {
    let result = ConstExprRunner(registry: terminalRegistry()).evaluateValue(
        source: "let answer = increment(40)",
        binding: "answer"
    )

    switch result {
    case .success(let value):
        #expect(try value.require(Int.self) == 41)
        #expect(value.renderedSource == "41")
    case .fallback(let fallback):
        Issue.record("unexpected fallback: \(fallback)")
    }
}

@Test func certifyingEvaluationRejectsAnUnknownActiveGlobal() {
    let result = ConstExprRunner(registry: terminalRegistry()).evaluate(
        source: """
            let external = unknownValue
            let package = TerminalBox(value: 1)
            """,
        binding: "package",
        as: TerminalBox.self,
        policy: .certifying
    )

    guard case .fallback(let fallback) = result else {
        Issue.record("certifying evaluation unexpectedly succeeded")
        return
    }
    #expect(fallback.reason == .unsupportedSource)
}

@Test func permissiveEvaluationMayIgnoreAnUnrelatedUnknownGlobal() {
    let result = ConstExprRunner(registry: terminalRegistry()).evaluate(
        source: """
            let external = unknownValue
            let package = TerminalBox(value: 1)
            """,
        binding: "package",
        as: TerminalBox.self,
        policy: .permissive
    )

    #expect(result == .success(TerminalBox(value: 1)))
}

@Test func terminalEvaluationReturnsStructuredParseAndTypeFallbacks() {
    let runner = ConstExprRunner(registry: terminalRegistry())
    let malformed = runner.evaluateValue(
        source: "let package = TerminalBox(value:",
        binding: "package"
    )
    guard case .fallback(let malformedFallback) = malformed else {
        Issue.record("malformed source unexpectedly succeeded")
        return
    }
    #expect(malformedFallback.reason == .malformedSource)
    #expect(malformedFallback.location != nil)

    let mismatch = runner.evaluate(
        source: "let package = TerminalBox(value: 1)",
        binding: "package",
        as: String.self
    )
    guard case .fallback(let mismatchFallback) = mismatch else {
        Issue.record("mismatched terminal type unexpectedly succeeded")
        return
    }
    #expect(mismatchFallback.reason == .typeMismatch)
}

@Test func structuralTypeKeysCanonicalizeSugarAndGenericSpellings() {
    #expect(
        ConstExprSourceTypeKey(sourceName: "[TerminalBox]?")
            == ConstExprSourceTypeKey(sourceName: "Optional<Array<TerminalBox>>")
    )
    #expect(
        ConstExprSourceTypeKey(sourceName: "[String: [Int]]")
            == ConstExprSourceTypeKey(
                sourceName: "Swift.Dictionary<Swift.String, Swift.Array<Swift.Int>>"
            )
    )
    #expect(
        ConstExprSourceTypeKey(sourceName: "Set<TerminalBox>")
            == ConstExprSourceTypeKey(sourceName: "Swift.Set<TerminalBox>")
    )

    let composition = ConstExprSourceTypeKey(sourceName: "P & Q")
    #expect(composition == ConstExprSourceTypeKey(sourceName: "P&Q"))
    #expect(composition?.sourceName == "P & Q")

    let qualifiedComposition = ConstExprSourceTypeKey(
        sourceName: "FirstModule.P&SecondModule.Q"
    )
    #expect(qualifiedComposition?.sourceName == "FirstModule.P & SecondModule.Q")
    #expect(qualifiedComposition?.lookupAliases.contains(composition!) == true)

    #expect(
        ConstExprSourceTypeKey(sourceName: "[(P & Q, Box<R&S>)]?")
            == ConstExprSourceTypeKey(sourceName: "Array<(P&Q, Box<R & S>)>?")
    )
}

@Test func registryTypeIndexRecoversNestedLeavesAndCachesStructuralLookups() {
    let registration = ConstExprRegistration(
        name: "consume",
        kind: .function,
        parameterLabels: [nil],
        parameterTypes: [[TerminalBox]?.self],
        resultType: Int.self
    ) { _, _ in ConstExprValue(0) }
    let registry = ConstExprRegistry(registrations: [registration])
    let resolver = ConstExprTypeResolver(index: registry.index)

    let generic = resolver.resolve(sourceName: "Optional<Array<TerminalBox>>")
    let sugar = resolver.resolve(sourceName: "[TerminalBox]?")

    #expect(generic?.type.map { ObjectIdentifier($0) } == ObjectIdentifier([TerminalBox]?.self))
    #expect(sugar?.type.map { ObjectIdentifier($0) } == ObjectIdentifier([TerminalBox]?.self))
    #expect(resolver.metrics.lookups == 2)
    #expect(resolver.metrics.cacheHits >= 1)
}

@Test func enablingSignpostsDoesNotChangeEvaluationSemantics() {
    let runner = ConstExprRunner(
        registry: terminalRegistry(),
        options: ConstExprRewriteOptions(enableSignposts: true)
    )
    let result = runner.rewrite(source: "let answer = increment(1)")

    #expect(result.source == "let answer = 2")
    #expect(result.diagnostics.isEmpty)
}

@Test func terminalEvaluationAcceptsAnAlreadyParsedSourceFile() {
    let sourceFile: SourceFileSyntax = "let answer = increment(40)"
    let result = ConstExprRunner(registry: terminalRegistry()).evaluate(
        sourceFile: sourceFile,
        binding: "answer",
        as: Int.self
    )

    #expect(result == .success(41))
}

@Test func terminalEvaluationPropagatesValuesWithoutRenderingSource() {
    let counter = TerminalRenderCounter()
    let registration = ConstExprRegistration(
        name: "probe",
        kind: .function,
        resultType: TerminalRenderProbe.self
    ) { _, _ in ConstExprValue(TerminalRenderProbe(counter: counter)) }
    let runner = ConstExprRunner(registry: ConstExprRegistry(registration))

    let terminal = runner.evaluate(
        source: "let value = probe()",
        binding: "value",
        as: TerminalRenderProbe.self
    )
    guard case .success = terminal else {
        Issue.record("terminal probe unexpectedly fell back")
        return
    }
    #expect(counter.calls == 0)

    #expect(runner.rewrite(source: "let value = probe()").source == "let value = 123")
    #expect(counter.calls == 1)
}

@Test func unresolvedRequestedBindingPrecedesGenericCertificationFailure() {
    let result = ConstExprRunner(registry: terminalRegistry()).evaluateValue(
        source: "let package = missingValue",
        binding: "package",
        policy: .certifying,
        fileName: "Package.swift"
    )

    guard case .fallback(let fallback) = result else {
        Issue.record("unresolved requested binding unexpectedly succeeded")
        return
    }
    #expect(fallback.reason == .unresolvedBinding)
    #expect(fallback.location?.fileName == "Package.swift")
    #expect(fallback.location?.line == 1)
}

@Test func certifyingEvaluationRejectsDuplicateGlobalBindingNames() {
    let result = ConstExprRunner(registry: terminalRegistry()).evaluateValue(
        source: """
            let package = TerminalBox(value: 1)
            let package = TerminalBox(value: 2)
            """,
        binding: "package",
        policy: .certifying
    )

    guard case .fallback(let fallback) = result else {
        Issue.record("duplicate global bindings unexpectedly certified")
        return
    }
    #expect(fallback.reason == .unsupportedSource)
    #expect(fallback.message.contains("duplicate active global binding 'package'"))
    #expect(fallback.location?.line == 2)
}
