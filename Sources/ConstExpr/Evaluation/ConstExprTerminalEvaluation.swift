import SwiftSyntax

/// Controls how much source must be proven safe before a terminal value is
/// returned. Certifying evaluation is intended for fast paths that will skip
/// normal Swift compilation when it succeeds.
public enum ConstExprEvaluationPolicy: String, Sendable, Equatable {
    /// Return the requested binding when it resolves, even if unrelated source
    /// remains unknown.
    case permissive
    /// Require every active top-level declaration to be an import or a fully
    /// evaluated immutable binding.
    case certifying
}

public struct ConstExprEvaluationFallback: Error, Sendable, Equatable {
    public enum Reason: String, Sendable, Equatable, CaseIterable {
        case invalidRegistry = "invalid-registry"
        case malformedSource = "malformed-source"
        case operatorResolution = "operator-resolution"
        case unsupportedSource = "unsupported-source"
        case unresolvedBinding = "unresolved-binding"
        case ambiguousResolution = "ambiguous-resolution"
        case resourceLimit = "resource-limit"
        case evaluationFailed = "evaluation-failed"
        case typeMismatch = "type-mismatch"
    }

    public let reason: Reason
    public let message: String
    public let location: ConstExprSourceLocation?
    public let diagnostics: [ConstExprDiagnostic]

    public init(
        reason: Reason,
        message: String,
        location: ConstExprSourceLocation? = nil,
        diagnostics: [ConstExprDiagnostic] = []
    ) {
        self.reason = reason
        self.message = message
        self.location = location
        self.diagnostics = diagnostics
    }
}

public enum ConstExprTerminalEvaluation<Value> {
    case success(Value)
    case fallback(ConstExprEvaluationFallback)

    public func map<Mapped>(
        _ transform: (Value) throws -> Mapped
    ) rethrows -> ConstExprTerminalEvaluation<Mapped> {
        switch self {
        case .success(let value): return .success(try transform(value))
        case .fallback(let fallback): return .fallback(fallback)
        }
    }
}

extension ConstExprTerminalEvaluation: Sendable where Value: Sendable {}
extension ConstExprTerminalEvaluation: Equatable where Value: Equatable {}

public extension ConstExprRunner {
    /// Evaluates a named global binding without materializing rewritten source.
    /// The returned value retains opaque linked Swift values for callers that
    /// need a type-erased result or want to render it themselves.
    func evaluateValue(
        source: String,
        binding: String,
        policy: ConstExprEvaluationPolicy = .certifying,
        fileName: String = "<memory>"
    ) -> ConstExprTerminalEvaluation<ConstExprValue> {
        let wholeInterval = ConstExprInstrumentation.begin(
            "TerminalEvaluation",
            enabled: options.enableSignposts
        )
        defer { ConstExprInstrumentation.end(wholeInterval) }
        return evaluateValue(
            prepared: prepare(source: source, fileName: fileName),
            binding: binding,
            policy: policy,
            fileName: fileName
        )
    }

    /// Evaluates an already parsed/configured source file. Callers that remove
    /// inactive `#if` clauses can reuse that exact tree without a second parse;
    /// diagnostics and operator folding still run before evaluation.
    func evaluateValue(
        sourceFile: SourceFileSyntax,
        binding: String,
        policy: ConstExprEvaluationPolicy = .certifying,
        fileName: String = "<memory>"
    ) -> ConstExprTerminalEvaluation<ConstExprValue> {
        let wholeInterval = ConstExprInstrumentation.begin(
            "TerminalEvaluation",
            enabled: options.enableSignposts
        )
        defer { ConstExprInstrumentation.end(wholeInterval) }
        return evaluateValue(
            prepared: prepare(sourceFile: sourceFile, fileName: fileName),
            binding: binding,
            policy: policy,
            fileName: fileName
        )
    }

    private func evaluateValue(
        prepared: ConstExprPreparedSource,
        binding: String,
        policy: ConstExprEvaluationPolicy,
        fileName: String
    ) -> ConstExprTerminalEvaluation<ConstExprValue> {
        guard let folded = prepared.foldedSyntax else {
            return .fallback(Self.preparationFallback(prepared.diagnostics))
        }
        if let registryError = prepared.diagnostics.first(where: {
            $0.isError && ($0.code == "registry-collision" || $0.code == "invalid-registration")
        }) {
            return .fallback(ConstExprEvaluationFallback(
                reason: .invalidRegistry,
                message: registryError.message,
                location: registryError.location,
                diagnostics: prepared.diagnostics
            ))
        }

        let evaluator = ConstExprSourceEvaluator(
            registry: registry,
            maximumNodeCount: max(1, options.maximumEvaluationSteps),
            maximumDepth: max(1, options.maximumRecursionDepth),
            availabilityContext: options.availabilityContext,
            materializesSource: false
        )
        defer {
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
        }
        let evaluationInterval = ConstExprInstrumentation.begin(
            "ExpressionEvaluation",
            enabled: options.enableSignposts
        )
        _ = ConstExprSourceRewriter(evaluator: evaluator).rewrite(folded)
        ConstExprInstrumentation.end(evaluationInterval)
        let diagnostics = prepared.diagnostics + Self.diagnostics(
            from: evaluator,
            tree: folded,
            fileName: fileName
        )
        guard case .constant(let terminalValue)? = evaluator.scopes.binding(named: binding) else {
            return .fallback(Self.unresolvedBindingFallback(
                binding: binding,
                sourceFile: folded,
                diagnostics: diagnostics,
                encounteredUnknownAvailability: evaluator.encounteredUnknownAvailability,
                fileName: fileName
            ))
        }

        let certificationInterval = ConstExprInstrumentation.begin(
            "Certification",
            enabled: options.enableSignposts && policy == .certifying
        )
        if policy == .certifying,
           let fallback = Self.certificationFallback(
               sourceFile: folded,
               evaluator: evaluator,
               diagnostics: diagnostics,
               fileName: fileName
           )
        {
            ConstExprInstrumentation.end(certificationInterval)
            return .fallback(fallback)
        }
        ConstExprInstrumentation.end(certificationInterval)
        if let diagnostic = diagnostics.first(where: { Self.isResolutionFailure($0.code) }) {
            return .fallback(ConstExprEvaluationFallback(
                reason: Self.fallbackReason(for: diagnostic.code),
                message: diagnostic.message,
                location: diagnostic.location,
                diagnostics: diagnostics
            ))
        }
        let extractionInterval = ConstExprInstrumentation.begin(
            "TerminalExtraction",
            enabled: options.enableSignposts
        )
        defer { ConstExprInstrumentation.end(extractionInterval) }
        return .success(terminalValue.erasingLiteralProvenance())
    }

    /// Evaluates and decodes a named global binding as an exact runtime type.
    /// Opaque values produced by registrations can cross module boundaries as
    /// long as the caller supplies their linked type here.
    func evaluate<Value>(
        source: String,
        binding: String,
        as type: Value.Type,
        policy: ConstExprEvaluationPolicy = .certifying,
        fileName: String = "<memory>"
    ) -> ConstExprTerminalEvaluation<Value> {
        switch evaluateValue(
            source: source,
            binding: binding,
            policy: policy,
            fileName: fileName
        ) {
        case .success(let value):
            do {
                return .success(try value.require(type))
            } catch {
                return .fallback(ConstExprEvaluationFallback(
                    reason: .typeMismatch,
                    message: "binding '\(binding)' is not decodable as \(String(reflecting: type)): \(error)"
                ))
            }
        case .fallback(let fallback):
            return .fallback(fallback)
        }
    }

    /// Typed counterpart of ``evaluateValue(sourceFile:binding:policy:fileName:)``.
    func evaluate<Value>(
        sourceFile: SourceFileSyntax,
        binding: String,
        as type: Value.Type,
        policy: ConstExprEvaluationPolicy = .certifying,
        fileName: String = "<memory>"
    ) -> ConstExprTerminalEvaluation<Value> {
        switch evaluateValue(
            sourceFile: sourceFile,
            binding: binding,
            policy: policy,
            fileName: fileName
        ) {
        case .success(let value):
            do {
                return .success(try value.require(type))
            } catch {
                return .fallback(ConstExprEvaluationFallback(
                    reason: .typeMismatch,
                    message: "binding '\(binding)' is not decodable as \(String(reflecting: type)): \(error)"
                ))
            }
        case .fallback(let fallback):
            return .fallback(fallback)
        }
    }
}

private extension ConstExprRunner {
    static func diagnostics(
        from evaluator: ConstExprSourceEvaluator,
        tree: SourceFileSyntax,
        fileName: String
    ) -> [ConstExprDiagnostic] {
        guard !evaluator.events.isEmpty else { return [] }
        let converter = SourceLocationConverter(fileName: fileName, tree: tree)
        return evaluator.events.map { event in
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
        }
    }

    static func preparationFallback(
        _ diagnostics: [ConstExprDiagnostic]
    ) -> ConstExprEvaluationFallback {
        let diagnostic = diagnostics.first(where: \ConstExprDiagnostic.isError)
            ?? diagnostics.first
        let reason: ConstExprEvaluationFallback.Reason
        switch diagnostic?.code {
        case "registry-collision", "invalid-registration": reason = .invalidRegistry
        case "operator-error", "operator-registration-error", "operator-registration-conflict":
            reason = .operatorResolution
        default: reason = .malformedSource
        }
        return ConstExprEvaluationFallback(
            reason: reason,
            message: diagnostic?.message ?? "source preparation failed",
            location: diagnostic?.location,
            diagnostics: diagnostics
        )
    }

    static func certificationFallback(
        sourceFile: SourceFileSyntax,
        evaluator: ConstExprSourceEvaluator,
        diagnostics: [ConstExprDiagnostic],
        fileName: String
    ) -> ConstExprEvaluationFallback? {
        if let diagnostic = diagnostics.first(where: { isResolutionFailure($0.code) }) {
            return ConstExprEvaluationFallback(
                reason: fallbackReason(for: diagnostic.code),
                message: diagnostic.message,
                location: diagnostic.location,
                diagnostics: diagnostics
            )
        }

        if evaluator.encounteredUnknownAvailability {
            return ConstExprEvaluationFallback(
                reason: .unsupportedSource,
                message: "availability context cannot prove a complete overload set",
                diagnostics: diagnostics
            )
        }
        var declaredBindings: Set<String> = []
        for item in sourceFile.statements {
            guard case .decl(let declaration) = item.item else {
                return unsupported(
                    item,
                    sourceFile: sourceFile,
                    fileName: fileName,
                    diagnostics: diagnostics
                )
            }
            if declaration.is(ImportDeclSyntax.self) { continue }
            guard let variable = declaration.as(VariableDeclSyntax.self),
                  variable.bindingSpecifier.tokenKind == .keyword(.let),
                  variable.attributes.isEmpty
            else {
                return unsupported(
                    item,
                    sourceFile: sourceFile,
                    fileName: fileName,
                    diagnostics: diagnostics
                )
            }
            for binding in variable.bindings {
                guard let identifier = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else {
                    return unsupported(
                        item,
                        message: "certifying evaluation found a non-identifier active global binding",
                        sourceFile: sourceFile,
                        fileName: fileName,
                        diagnostics: diagnostics
                    )
                }
                guard declaredBindings.insert(identifier).inserted else {
                    return unsupported(
                        item,
                        message: "certifying evaluation found duplicate active global binding '\(identifier)'",
                        sourceFile: sourceFile,
                        fileName: fileName,
                        diagnostics: diagnostics
                    )
                }
                guard binding.accessorBlock == nil,
                      binding.initializer != nil,
                      case .constant? = evaluator.scopes.binding(named: identifier)
                else {
                    return unsupported(
                        item,
                        sourceFile: sourceFile,
                        fileName: fileName,
                        diagnostics: diagnostics
                    )
                }
            }
        }
        return nil
    }

    static func unsupported(
        _ item: CodeBlockItemSyntax,
        message: String = "certifying evaluation found an unsupported active top-level statement",
        sourceFile: SourceFileSyntax,
        fileName: String,
        diagnostics: [ConstExprDiagnostic]
    ) -> ConstExprEvaluationFallback {
        let converter = SourceLocationConverter(fileName: fileName, tree: sourceFile)
        let location = converter.location(for: item.positionAfterSkippingLeadingTrivia)
        return ConstExprEvaluationFallback(
            reason: .unsupportedSource,
            message: message,
            location: ConstExprSourceLocation(
                fileName: fileName,
                line: location.line,
                column: location.column,
                offset: item.positionAfterSkippingLeadingTrivia.utf8Offset
            ),
            diagnostics: diagnostics
        )
    }

    static func unresolvedBindingFallback(
        binding name: String,
        sourceFile: SourceFileSyntax,
        diagnostics: [ConstExprDiagnostic],
        encounteredUnknownAvailability: Bool,
        fileName: String
    ) -> ConstExprEvaluationFallback {
        let matchingBinding = sourceFile.statements.lazy.compactMap { item -> PatternBindingSyntax? in
            guard case .decl(let declaration) = item.item,
                  let variable = declaration.as(VariableDeclSyntax.self)
            else { return nil }
            return variable.bindings.first {
                $0.pattern.as(IdentifierPatternSyntax.self)?.identifier.text == name
            }
        }.first
        let relevantDiagnostic = matchingBinding.flatMap { binding in
            diagnostics.first { diagnostic in
                guard let offset = diagnostic.offset else { return false }
                return offset >= binding.positionAfterSkippingLeadingTrivia.utf8Offset
                    && offset < binding.endPositionBeforeTrailingTrivia.utf8Offset
            }
        }
        let location = relevantDiagnostic?.location ?? matchingBinding.map { binding in
            let converter = SourceLocationConverter(fileName: fileName, tree: sourceFile)
            let position = binding.positionAfterSkippingLeadingTrivia
            let sourceLocation = converter.location(for: position)
            return ConstExprSourceLocation(
                fileName: fileName,
                line: sourceLocation.line,
                column: sourceLocation.column,
                offset: position.utf8Offset
            )
        }
        return ConstExprEvaluationFallback(
            reason: .unresolvedBinding,
            message: relevantDiagnostic?.message
                ?? (encounteredUnknownAvailability
                    ? "availability context cannot prove a complete overload set"
                    : nil)
                ?? "global binding '\(name)' could not be proven constant",
            location: location,
            diagnostics: diagnostics
        )
    }

    static func isResolutionFailure(_ code: String) -> Bool {
        code.hasPrefix("ambiguous-")
            || code == "no-matching-overload"
            || code == "evaluation-threw"
            || code == "maximum-depth"
            || code == "maximum-node-count"
            || code == "array-literal-element-limit"
            || code == "forced-unwrap-of-nil"
            || code == "subscript-out-of-bounds"
            || code == "duplicate-dictionary-key"
    }

    static func fallbackReason(
        for diagnosticCode: String
    ) -> ConstExprEvaluationFallback.Reason {
        if diagnosticCode.hasPrefix("ambiguous-") { return .ambiguousResolution }
        if diagnosticCode == "maximum-depth" || diagnosticCode == "maximum-node-count" {
            return .resourceLimit
        }
        return .evaluationFailed
    }
}
