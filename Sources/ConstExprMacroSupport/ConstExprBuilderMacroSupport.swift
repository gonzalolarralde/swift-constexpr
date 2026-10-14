import ConstExpr
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// Opt-in support for library-owned, straight-line result-builder macros.
///
/// The library supplies a pure registered builder with `buildExpression`, both
/// `buildPartialBlock` methods, `buildFinalResult`, and an empty `buildBlock`.
/// These methods must have the same unambiguous behavior in the host registry
/// and the consumer. This is a deliberately limited transform, not Swift's
/// general result-builder type checker: control flow, effects, and explicit
/// signatures are left to the runtime function with its real builder annotation.
public enum ConstExprBuilderMacroSupport {
    public static func expansion(
        of macro: some FreestandingMacroExpansionSyntax,
        in context: some MacroExpansionContext,
        registry: ConstExprRegistry,
        builderType: String,
        runtimeFunction: String,
        requireConstantArgumentLabel: String? = nil,
        options: ConstExprRewriteOptions = .init()
    ) -> ExprSyntax {
        let name = macro.macroName.text
        let closure = macro.trailingClosure
            ?? macro.arguments.last?.expression.as(ClosureExprSyntax.self)
        guard let closure else {
            diagnose("#\(name) requires a closure", on: macro, in: context)
            return ExprSyntax(stringLiteral: "fatalError(\"missing macro closure\")")
        }
        let fallback = ExprSyntax(stringLiteral: "\(runtimeFunction) \(closure.trimmedDescription)")
        var requireConstant = false
        if let label = requireConstantArgumentLabel,
           let argument = macro.arguments.first(where: { $0.label?.text == label }) {
            guard let literal = argument.expression.as(BooleanLiteralExprSyntax.self) else {
                diagnose("#\(name) requires a literal true or false for '\(label)'", on: macro, in: context)
                return fallback
            }
            requireConstant = literal.literal.tokenKind == .keyword(.true)
        }

        func fail(_ reason: String) -> ExprSyntax {
            if requireConstant {
                diagnose("#\(name) could not produce a compile-time constant: \(reason)", on: macro, in: context)
            }
            return fallback
        }
        guard let source = loweredSource(closure, builder: builderType, in: context) else {
            return fail("only synchronous, nonthrowing straight-line expressions and immutable local bindings are supported")
        }
        switch ConstExprRunner(registry: registry, options: options).evaluateValue(
            source: source.text,
            binding: source.result,
            policy: .certifying,
            fileName: "<ConstExpr #\(name)>"
        ) {
        case .success(let value):
            do { return try value.constExprExpression() }
            catch { return fail("the result cannot be represented as Swift source") }
        case .fallback(let failure):
            return fail(failure.message)
        }
    }

    private static func loweredSource(
        _ closure: ClosureExprSyntax,
        builder: String,
        in context: some MacroExpansionContext
    ) -> (text: String, result: String)? {
        guard closure.signature == nil else { return nil }
        // Moving the body to top-level source must not erase an inferred
        // throwing/async closure effect or repair an invalid consumer program.
        let effects = EffectVisitor(viewMode: .sourceAccurate)
        effects.walk(closure.statements)
        guard !effects.found else { return nil }
        var lines: [String] = []
        var components: [String] = []
        for item in closure.statements {
            switch item.item {
            case .decl(let declaration):
                guard let binding = declaration.as(VariableDeclSyntax.self),
                      binding.bindingSpecifier.tokenKind == .keyword(.let),
                      binding.attributes.isEmpty, binding.modifiers.isEmpty,
                      binding.bindings.allSatisfy({ $0.initializer != nil && $0.accessorBlock == nil })
                else { return nil }
                lines.append(binding.trimmedDescription)
            case .expr(let expression):
                guard !expression.is(IfExprSyntax.self), !expression.is(SwitchExprSyntax.self) else { return nil }
                let component = context.makeUniqueName("constExprComponent").text
                lines.append("let \(component) = \(builder).buildExpression(\(expression.trimmedDescription))")
                components.append(component)
            default:
                return nil
            }
        }
        // SE-0348 evaluates all expressions before accumulating partial blocks.
        // Keep that ordering, including local declarations between expressions.
        var partial = context.makeUniqueName("constExprPartial").text
        if let first = components.first {
            lines.append("let \(partial) = \(builder).buildPartialBlock(first: \(first))")
            for next in components.dropFirst() {
                let combined = context.makeUniqueName("constExprPartial").text
                lines.append("let \(combined) = \(builder).buildPartialBlock(accumulated: \(partial), next: \(next))")
                partial = combined
            }
        } else {
            lines.append("let \(partial) = \(builder).buildBlock()")
        }
        let result = context.makeUniqueName("constExprBuilderResult").text
        lines.append("let \(result) = \(builder).buildFinalResult(\(partial))")
        return (lines.joined(separator: "\n"), result)
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
