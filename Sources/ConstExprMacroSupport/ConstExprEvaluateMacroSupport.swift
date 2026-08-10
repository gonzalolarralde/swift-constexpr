import ConstExpr
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// Shared implementation for library-owned `#evaluate` companion macros.
///
/// A companion macro target supplies the concrete registry linked into its
/// host executable. This support type deliberately does not attempt to discover
/// declarations from the consumer module.
public enum ConstExprEvaluateMacroSupport {
    public static func expansion(
        of macro: some FreestandingMacroExpansionSyntax,
        in context: some MacroExpansionContext,
        registry: ConstExprRegistry,
        options: ConstExprRewriteOptions = .init()
    ) -> ExprSyntax {
        guard let closure = closureArgument(of: macro) else {
            return ExprSyntax(stringLiteral: "({ fatalError(\"#evaluate requires a closure\") })()")
        }
        let fallback = fallbackExpression(for: closure)
        guard let body = evaluableBody(of: closure) else { return fallback }

        let resultName = context.makeUniqueName("constExprEvaluateResult").text
        let prefix = body.bindings.map(\.description).joined(separator: "\n")
        let source = [
            prefix,
            "let \(resultName) = \(body.result.description)",
        ].filter { !$0.isEmpty }.joined(separator: "\n")

        switch ConstExprRunner(registry: registry, options: options).evaluateValue(
            source: source,
            binding: resultName,
            policy: .certifying,
            fileName: "<ConstExpr #evaluate>"
        ) {
        case .success(let value):
            return (try? value.constExprExpression()) ?? fallback
        case .fallback:
            return fallback
        }
    }

    private struct EvaluableBody {
        let bindings: [VariableDeclSyntax]
        let result: ExprSyntax
    }

    private static func closureArgument(
        of macro: some FreestandingMacroExpansionSyntax
    ) -> ClosureExprSyntax? {
        if let trailingClosure = macro.trailingClosure { return trailingClosure }
        return macro.arguments.last?.expression.as(ClosureExprSyntax.self)
    }

    private static func evaluableBody(
        of closure: ClosureExprSyntax
    ) -> EvaluableBody? {
        guard closure.signature == nil, !closure.statements.isEmpty else { return nil }
        var bindings: [VariableDeclSyntax] = []
        let items = Array(closure.statements)

        for item in items.dropLast() {
            guard case .decl(let declaration) = item.item,
                  let variable = declaration.as(VariableDeclSyntax.self),
                  variable.bindingSpecifier.tokenKind == .keyword(.let),
                  variable.attributes.isEmpty,
                  variable.bindings.allSatisfy({
                      $0.initializer != nil && $0.accessorBlock == nil
                  })
            else {
                return nil
            }
            bindings.append(variable)
        }

        guard let last = items.last else { return nil }
        if case .expr(let expression) = last.item {
            return EvaluableBody(bindings: bindings, result: expression)
        }
        if case .stmt(let statement) = last.item,
           let returnStatement = statement.as(ReturnStmtSyntax.self),
           let expression = returnStatement.expression
        {
            return EvaluableBody(bindings: bindings, result: expression)
        }
        return nil
    }

    private static func fallbackExpression(
        for closure: ClosureExprSyntax
    ) -> ExprSyntax {
        let items = Array(closure.statements)
        if closure.signature == nil,
           items.count == 1,
           let only = items.first,
           case .expr(let expression) = only.item
        {
            return expression
        }
        return ExprSyntax(stringLiteral: "(\(closure.description))()")
    }
}
