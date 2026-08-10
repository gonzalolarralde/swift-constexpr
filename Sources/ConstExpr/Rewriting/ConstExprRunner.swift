import SwiftOperators
import SwiftParser
import SwiftParserDiagnostics
import SwiftSyntax

/// Rewrites every expression that can be proven constant using the supplied
/// registrations. Unsupported source is retained verbatim wherever possible.
public struct ConstExprRunner: Sendable {
    public let registry: ConstExprRegistry
    public let options: ConstExprRewriteOptions

    public init(
        registry: ConstExprRegistry,
        options: ConstExprRewriteOptions = .init()
    ) {
        self.registry = registry
        self.options = options
    }

    public func rewrite(
        source: String,
        fileName: String = "<memory>"
    ) -> ConstExprRewriteResult {
        let wholeInterval = ConstExprInstrumentation.begin(
            "Rewrite",
            enabled: options.enableSignposts
        )
        defer { ConstExprInstrumentation.end(wholeInterval) }
        let prepared = prepare(source: source, fileName: fileName)
        guard let folded = prepared.foldedSyntax else {
            return ConstExprRewriteResult(source: source, diagnostics: prepared.diagnostics)
        }
        var diagnostics = prepared.diagnostics

        let evaluator = ConstExprSourceEvaluator(
            registry: registry,
            maximumNodeCount: max(1, options.maximumEvaluationSteps),
            maximumDepth: max(1, options.maximumRecursionDepth),
            availabilityContext: options.availabilityContext
        )
        let evaluationInterval = ConstExprInstrumentation.begin(
            "ExpressionEvaluation",
            enabled: options.enableSignposts
        )
        let rewrittenSyntax = ConstExprSourceRewriter(evaluator: evaluator).rewrite(folded)
        ConstExprInstrumentation.end(evaluationInterval)
        let rewritten = rewrittenSyntax.cast(SourceFileSyntax.self)
        if !evaluator.events.isEmpty {
            let converter = SourceLocationConverter(fileName: fileName, tree: folded)
            diagnostics.append(contentsOf: evaluator.events.map { event in
                let location = converter.location(for: event.position)
                let severity: ConstExprDiagnostic.Severity
                switch event.severity {
                case .note: severity = .note
                case .warning: severity = .warning
                case .error: severity = .error
                }
                return ConstExprDiagnostic(
                    severity: severity,
                    code: event.code,
                    message: event.message,
                    fileName: fileName,
                    line: location.line,
                    column: location.column,
                    offset: event.position.utf8Offset
                )
            })
        }
        diagnostics.sort {
            ($0.line, $0.column, $0.code, $0.message)
                < ($1.line, $1.column, $1.code, $1.message)
        }

        ConstExprInstrumentation.evaluationMetrics(
            nodeCount: evaluator.evaluatedNodeCount,
            candidateRegistrationCount: evaluator.candidateRegistrationCount,
            renderedReplacementCount: evaluator.renderedReplacementCount,
            enabled: options.enableSignposts
        )
        ConstExprInstrumentation.typeResolutionMetrics(
            evaluator.typeResolver.metrics,
            enabled: options.enableSignposts
        )
        let materializationInterval = ConstExprInstrumentation.begin(
            "SourceMaterialization",
            enabled: options.enableSignposts
        )
        let rewrittenSource = rewritten.description
        ConstExprInstrumentation.end(materializationInterval)
        let output = prepared.hasByteOrderMark && rewrittenSource.first != "\u{FEFF}"
            ? "\u{FEFF}" + rewrittenSource
            : rewrittenSource
        return ConstExprRewriteResult(source: output, diagnostics: diagnostics)
    }

    func prepare(source: String, fileName: String) -> ConstExprPreparedSource {
        let hasByteOrderMark = source.first == "\u{FEFF}"
        let parseInterval = ConstExprInstrumentation.begin(
            "Parse",
            enabled: options.enableSignposts
        )
        let parsed = Parser.parse(source: source)
        ConstExprInstrumentation.end(parseInterval)
        return prepare(
            sourceFile: parsed,
            fileName: fileName,
            hasByteOrderMark: hasByteOrderMark
        )
    }

    func prepare(
        sourceFile: SourceFileSyntax,
        fileName: String,
        hasByteOrderMark: Bool = false
    ) -> ConstExprPreparedSource {
        let registryInterval = ConstExprInstrumentation.begin(
            "RegistryIndex",
            enabled: options.enableSignposts
        )
        _ = registry.index
        ConstExprInstrumentation.end(registryInterval)
        let diagnosticsInterval = ConstExprInstrumentation.begin(
            "Diagnostics",
            enabled: options.enableSignposts
        )
        let parseDiagnostics = ParseDiagnosticsGenerator.diagnostics(for: sourceFile)
        var converter: SourceLocationConverter?
        func sourceLocation(for position: AbsolutePosition) -> SourceLocation {
            let active = converter
                ?? SourceLocationConverter(fileName: fileName, tree: sourceFile)
            converter = active
            return active.location(for: position)
        }
        var diagnostics = parseDiagnostics.map { diagnostic -> ConstExprDiagnostic in
            let location = sourceLocation(for: diagnostic.position)
            let severity: ConstExprDiagnostic.Severity
            switch diagnostic.diagMessage.severity {
            case .error: severity = .error
            case .warning: severity = .warning
            case .note, .remark: severity = .note
            }
            return ConstExprDiagnostic(
                severity: severity,
                code: "parse-error",
                message: diagnostic.message,
                fileName: fileName,
                line: location.line,
                column: location.column,
                offset: diagnostic.position.utf8Offset
            )
        }
        diagnostics.append(contentsOf: registry.validationDiagnostics.map { diagnostic in
            ConstExprDiagnostic(
                severity: diagnostic.severity,
                code: diagnostic.code,
                message: diagnostic.message,
                fileName: fileName,
                line: diagnostic.line,
                column: diagnostic.column,
                offset: diagnostic.offset
            )
        })
        ConstExprInstrumentation.end(diagnosticsInterval)
        if diagnostics.contains(where: { $0.code == "parse-error" && $0.isError }) {
            return failedPreparation(
                diagnostics: diagnostics,
                hasByteOrderMark: hasByteOrderMark
            )
        }

        let operatorInterval = ConstExprInstrumentation.begin(
            "OperatorFolding",
            enabled: options.enableSignposts
        )
        var operatorTable = OperatorTable.standardOperators
        var operatorErrors: [OperatorError] = []
        operatorTable.addSourceFile(sourceFile) { operatorErrors.append($0) }
        let registrationDiagnostics = installRegisteredOperatorDeclarations(
            in: &operatorTable,
            sourceFile: sourceFile,
            fileName: fileName
        )
        diagnostics.append(contentsOf: registrationDiagnostics)
        let folded = operatorTable.foldAll(sourceFile) { operatorErrors.append($0) }
        var seenErrors: Set<String> = []
        for error in operatorErrors {
            let diagnostic = error.asDiagnostic
            let location = sourceLocation(for: diagnostic.position)
            let key = "\(location.line):\(location.column):\(diagnostic.message)"
            guard seenErrors.insert(key).inserted else { continue }
            diagnostics.append(ConstExprDiagnostic(
                severity: .error,
                code: "operator-error",
                message: diagnostic.message,
                fileName: fileName,
                line: location.line,
                column: location.column,
                offset: diagnostic.position.utf8Offset
            ))
        }
        if !operatorErrors.isEmpty || registrationDiagnostics.contains(where: \ConstExprDiagnostic.isError) {
            ConstExprInstrumentation.end(operatorInterval)
            return failedPreparation(
                diagnostics: diagnostics,
                hasByteOrderMark: hasByteOrderMark
            )
        }
        ConstExprInstrumentation.end(operatorInterval)
        diagnostics.sort(by: Self.diagnosticOrder)
        return ConstExprPreparedSource(
            foldedSyntax: folded.cast(SourceFileSyntax.self),
            diagnostics: diagnostics,
            hasByteOrderMark: hasByteOrderMark
        )
    }

    private func failedPreparation(
        diagnostics: [ConstExprDiagnostic],
        hasByteOrderMark: Bool
    ) -> ConstExprPreparedSource {
        ConstExprPreparedSource(
            foldedSyntax: nil,
            diagnostics: diagnostics.sorted(by: Self.diagnosticOrder),
            hasByteOrderMark: hasByteOrderMark
        )
    }

    private static func diagnosticOrder(
        _ lhs: ConstExprDiagnostic,
        _ rhs: ConstExprDiagnostic
    ) -> Bool {
        (lhs.line, lhs.column, lhs.code, lhs.message)
            < (rhs.line, rhs.column, rhs.code, rhs.message)
    }

    /// Compatibility convenience for callers interested only in rewritten
    /// source. Diagnostics remain available through ``rewrite(source:fileName:)``.
    public func run(input: String) -> String {
        rewrite(source: input).source
    }

}
