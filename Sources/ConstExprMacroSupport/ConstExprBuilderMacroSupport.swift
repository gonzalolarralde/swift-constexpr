import ConstExprEvaluation
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// Opt-in lowering for registered, pure result builders. The runtime builder
/// remains authoritative for unsupported syntax and dynamic branch conditions.
public enum ConstExprBuilderMacroSupport {
    public static func expansion(
        of macro: some FreestandingMacroExpansionSyntax,
        in context: some MacroExpansionContext,
        registry: ConstExprRegistry,
        builderType: String,
        runtimeFunction: String,
        runtimeBuilderType: String? = nil,
        policy: ConstExprMacroEvaluationPolicy = .bestEffort,
        supportsBranches: Bool = false,
        options: ConstExprRewriteOptions = .init()
    ) -> ExprSyntax {
        let prepared = prepare(
            of: macro, in: context, registry: registry, builderType: builderType,
            runtimeFunction: runtimeFunction, runtimeBuilderType: runtimeBuilderType,
            supportsBranches: supportsBranches, options: options
        )
        var failureReason = prepared.failureReason
        if let value = prepared.constantValue {
            do { return try value.constExprExpression() }
            catch { failureReason = "the result cannot be represented as Swift source" }
        }
        if policy == .requireConstant, let failureReason {
            diagnoseNonConstant(failureReason, of: macro, in: context)
            return prepared.fallbackExpression
        }
        return prepared.runtimeExpression
    }

    public static func prepare(
        of macro: some FreestandingMacroExpansionSyntax,
        in context: some MacroExpansionContext,
        registry: ConstExprRegistry,
        builderType: String,
        runtimeFunction: String,
        runtimeBuilderType: String? = nil,
        supportsBranches: Bool = false,
        options: ConstExprRewriteOptions = .init()
    ) -> ConstExprPreparedBuilder {
        let name = macro.macroName.text
        let closure = macro.trailingClosure
            ?? macro.arguments.last?.expression.as(ClosureExprSyntax.self)
        guard let closure else {
            diagnose("#\(name) requires a closure", on: macro, in: context)
            let failure = ExprSyntax(stringLiteral: "fatalError(\"missing macro closure\")")
            return .init(runtimeExpression: failure, fallbackExpression: failure)
        }
        let fallback = ExprSyntax(stringLiteral: "\(runtimeFunction) \(closure.trimmedDescription)")
        let runner = ConstExprRunner(registry: registry, options: options)
        let source: (text: String, result: String, generatedBindings: Set<String>)?
        if supportsBranches {
            source = ConstExprBuilderBranchLowering(
                builder: builderType, runner: runner, context: context
            ).lower(closure)
        } else {
            source = loweredSource(closure, builder: builderType, in: context)
        }
        guard let source else {
            let forms = supportsBranches
                ? "expressions, immutable local bindings, and branches with known Boolean conditions"
                : "straight-line expressions and immutable local bindings"
            return .init(
                runtimeExpression: fallback, fallbackExpression: fallback,
                failureReason: "only synchronous, nonthrowing \(forms) are supported"
            )
        }
        let fileName = "<ConstExpr #\(name)>"
        let failureReason: String
        switch runner.evaluateValue(
            source: source.text, binding: source.result, policy: .certifying, fileName: fileName
        ) {
        case .success(let value):
            return .init(constantValue: value, runtimeExpression: fallback, fallbackExpression: fallback)
        case .fallback(let failure):
            failureReason = failure.message
        }
        let rewritten = runner.rewrite(source: source.text, fileName: fileName)
        let residual: ExprSyntax?
        if !rewritten.hasErrors, rewritten.source != source.text {
            residual = ConstExprBuilderResidual.expression(
                source: rewritten.source, result: source.result,
                generatedBindings: source.generatedBindings, builderType: builderType,
                runtimeBuilderType: runtimeBuilderType ?? builderType,
                builderAlias: context.makeUniqueName("constExprBuilderType").text
            )
        } else { residual = nil }
        return .init(
            runtimeExpression: residual ?? fallback, fallbackExpression: fallback,
            failureReason: failureReason
        )
    }

    public static func diagnoseNonConstant(
        _ reason: String,
        of macro: some FreestandingMacroExpansionSyntax,
        in context: some MacroExpansionContext
    ) {
        diagnose(
            "#\(macro.macroName.text) could not produce a compile-time constant: \(reason)",
            on: macro, in: context
        )
    }

    private static func loweredSource(
        _ closure: ClosureExprSyntax,
        builder: String,
        in context: some MacroExpansionContext
    ) -> (text: String, result: String, generatedBindings: Set<String>)? {
        guard closure.signature == nil else { return nil }
        // Moving the body to top-level source must not erase an inferred
        // throwing/async closure effect or repair an invalid consumer program.
        let effects = EffectVisitor(viewMode: .sourceAccurate)
        effects.walk(closure.statements)
        guard !effects.found else { return nil }
        var lines: [String] = []
        var components: [String] = []
        var generatedBindings: Set<String> = []
        let builderRoot = builder.split(separator: ".").first.map { String($0).filter { $0 != "`" } }
        for item in closure.statements {
            switch item.item {
            case .decl(let declaration):
                guard let binding = declaration.as(VariableDeclSyntax.self),
                      binding.bindingSpecifier.tokenKind == .keyword(.let),
                      binding.attributes.isEmpty, binding.modifiers.isEmpty,
                      binding.bindings.allSatisfy({
                          $0.initializer != nil && $0.accessorBlock == nil
                              && !$0.pattern.tokens(viewMode: .sourceAccurate).contains(where: {
                                  $0.text.filter { $0 != "`" } == builderRoot
                              })
                      })
                else { return nil }
                lines.append(binding.trimmedDescription)
            case .expr(let expression):
                guard !expression.is(IfExprSyntax.self), !expression.is(SwitchExprSyntax.self) else { return nil }
                let component = context.makeUniqueName("constExprComponent").text
                generatedBindings.insert(component)
                lines.append("let \(component) = \(builder).buildExpression(\(expression.trimmedDescription))")
                components.append(component)
            default:
                return nil
            }
        }
        // SE-0348 evaluates all expressions before accumulating partial blocks.
        // Keep that ordering, including local declarations between expressions.
        var partial = context.makeUniqueName("constExprPartial").text
        generatedBindings.insert(partial)
        if let first = components.first {
            lines.append("let \(partial) = \(builder).buildPartialBlock(first: \(first))")
            for next in components.dropFirst() {
                let combined = context.makeUniqueName("constExprPartial").text
                generatedBindings.insert(combined)
                lines.append("let \(combined) = \(builder).buildPartialBlock(accumulated: \(partial), next: \(next))")
                partial = combined
            }
        } else {
            lines.append("let \(partial) = \(builder).buildBlock()")
        }
        let result = context.makeUniqueName("constExprBuilderResult").text
        generatedBindings.insert(result)
        lines.append("let \(result) = \(builder).buildFinalResult(\(partial))")
        return (lines.joined(separator: "\n"), result, generatedBindings)
    }

    private static func diagnose(
        _ message: String,
        on node: some SyntaxProtocol,
        in context: some MacroExpansionContext
    ) {
        context.diagnose(Diagnostic(node: node, message: Message(message: message)))
    }

    private struct Message: DiagnosticMessage {
        let message: String
        let diagnosticID = MessageID(domain: "ConstExprBuilderMacroSupport", id: "constant-required")
        let severity: DiagnosticSeverity = .error
    }

    private final class EffectVisitor: SyntaxVisitor {
        var found = false

        override func visit(_ node: TryExprSyntax) -> SyntaxVisitorContinueKind {
            found = true
            return .skipChildren
        }

        override func visit(_ node: AwaitExprSyntax) -> SyntaxVisitorContinueKind {
            found = true
            return .skipChildren
        }
    }
}
