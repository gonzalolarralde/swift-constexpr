import ConstExprEvaluation
import SwiftSyntax

/// Chosen by the macro declaration, not by a runtime argument in its input.
public enum ConstExprMacroEvaluationPolicy: Sendable, Equatable {
    case bestEffort
    case requireConstant
}

/// A library can consume the opaque constant before choosing how to render it.
/// For example, an assembler can validate an intermediate representation and
/// emit instruction words rather than rendering the builder's source model.
public struct ConstExprPreparedBuilder {
    public let constantValue: ConstExprValue?
    public let runtimeExpression: ExprSyntax
    public let fallbackExpression: ExprSyntax
    public let failureReason: String?

    init(
        constantValue: ConstExprValue? = nil,
        runtimeExpression: ExprSyntax,
        fallbackExpression: ExprSyntax,
        failureReason: String? = nil
    ) {
        self.constantValue = constantValue
        self.runtimeExpression = runtimeExpression
        self.fallbackExpression = fallbackExpression
        self.failureReason = failureReason
    }
}
