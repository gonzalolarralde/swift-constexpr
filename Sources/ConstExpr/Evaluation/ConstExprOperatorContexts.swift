import Foundation
import SwiftSyntax

extension ConstExprSourceEvaluator {
    func isCompoundAssignmentOperator(_ symbol: String) -> Bool {
        guard symbol.hasSuffix("=") else { return false }
        return !["==", "!=", "<=", ">=", "===", "!==", "~="].contains(symbol)
    }

    /// Only operators whose built-in result has the same contextual type as
    /// their operands may inherit a result context. In particular, passing a
    /// `Bool` result context into `lhs == rhs` would incorrectly ask both
    /// operands to resolve as `Bool`.
    func infixOperatorPreservesOperandType(_ symbol: String) -> Bool {
        switch symbol {
        case "+", "-", "*", "/", "%", "&+", "&-", "&*",
            "&", "|", "^", "<<", ">>", "&&", "||":
            return true
        default:
            return false
        }
    }

    /// Swift may inject a concrete built-in operator result into one or more
    /// Optional layers. Those layers constrain the final result, not the
    /// operands. Peel them before evaluating the operands, while declining
    /// broad contexts such as `Any`, existentials, or class upcasts whose
    /// operator overload cannot be inferred syntactically.
    func builtinOperatorOperandContext(_ expectedTypeName: String?) -> String? {
        guard let expectedTypeName, !usesShadowedTypeName(expectedTypeName) else {
            return nil
        }
        var candidate = sourceTypeName(expectedTypeName)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while candidate.hasSuffix("?") {
            candidate.removeLast()
            candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if candidate.hasPrefix("("), candidate.hasSuffix(")") {
                candidate = String(candidate.dropFirst().dropLast())
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        guard builtinType(named: candidate) != nil
                || arrayElementSourceType(candidate) != nil
        else { return nil }
        return candidate
    }

    func evaluatePostfix(
        _ postfix: PostfixOperatorExprSyntax,
        depth: Int,
        allowRegisteredCalls: Bool
    ) -> ConstExprEvaluation {
        let operand = evaluate(
            postfix.expression,
            depth: depth + 1,
            allowRegisteredCalls: allowRegisteredCalls
        )
        var rewritten = postfix
        rewritten.expression = operand.syntax
        guard let value = operand.value else {
            return ConstExprEvaluation(syntax: ExprSyntax(rewritten), value: nil)
        }
        return evaluateRegisteredOperator(
            named: postfix.operator.text,
            kind: .postfixOperator,
            values: [value],
            original: ExprSyntax(postfix),
            fallback: ExprSyntax(rewritten),
            allowRegisteredCalls: allowRegisteredCalls
        )
    }
}
