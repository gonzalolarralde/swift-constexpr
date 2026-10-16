import ConstExpr
import SwiftSyntax

/// A type that can emit a Swift expression preserving the value's static type.
public protocol ConstExprRepresentable {
    func constExprExpression() throws -> ExprSyntax
}

extension ConstExprStructurallyErasedValue: ConstExprRepresentable {
    package func constExprExpression() throws -> ExprSyntax {
        try value.constExprExpression()
    }
}
