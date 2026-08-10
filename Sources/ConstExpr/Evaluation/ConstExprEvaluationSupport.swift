import Foundation
import SwiftParser
import SwiftParserDiagnostics
import SwiftSyntax

extension ConstExprSourceEvaluator {
    func erasingLiteralProvenance(_ value: ConstExprValue) -> ConstExprValue {
        value.erasingLiteralProvenance()
    }

    func evaluateWithUnknownLiteralContext(
        _ expression: ExprSyntax,
        depth: Int,
        allowRegisteredCalls: Bool
    ) -> ConstExprEvaluation {
        requireExplicitLiteralOperatorContext += 1
        defer { requireExplicitLiteralOperatorContext -= 1 }
        return evaluate(
            expression,
            depth: depth,
            allowRegisteredCalls: allowRegisteredCalls
        )
    }

    func evaluateSpeculatively(
        _ expression: ExprSyntax,
        depth: Int,
        expectedTypeName: String?,
        requiresExplicitLiteralContext: Bool = false
    ) -> ConstExprEvaluation {
        suppressEvaluationDiagnostics += 1
        defer { suppressEvaluationDiagnostics -= 1 }
        if requiresExplicitLiteralContext, expectedTypeName == nil {
            return evaluateWithUnknownLiteralContext(
                expression,
                depth: depth,
                allowRegisteredCalls: false
            )
        }
        return evaluate(
            expression,
            depth: depth,
            allowRegisteredCalls: false,
            expectedTypeName: expectedTypeName
        )
    }

    func containsPotentialRegisteredInvocation(_ expression: ExprSyntax) -> Bool {
        final class Finder: SyntaxVisitor {
            let registrations: [ConstExprRegistration]
            var found = false

            init(registrations: [ConstExprRegistration]) {
                self.registrations = registrations
                super.init(viewMode: .sourceAccurate)
            }

            override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
                found = true
                return .skipChildren
            }

            override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
                found = true
                return .skipChildren
            }

            override func visit(_ node: SubscriptCallExprSyntax) -> SyntaxVisitorContinueKind {
                found = true
                return .skipChildren
            }

            override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
                if registrations.contains(where: {
                    $0.name == node.baseName.text && $0.kind == .constant
                }) {
                    found = true
                }
                return .skipChildren
            }

            override func visit(_ node: PrefixOperatorExprSyntax) -> SyntaxVisitorContinueKind {
                if registrations.contains(where: {
                    $0.name == node.operator.text && $0.kind == .prefixOperator
                }) {
                    found = true
                    return .skipChildren
                }
                return .visitChildren
            }

            override func visit(_ node: PostfixOperatorExprSyntax) -> SyntaxVisitorContinueKind {
                if registrations.contains(where: {
                    $0.name == node.operator.text && $0.kind == .postfixOperator
                }) {
                    found = true
                    return .skipChildren
                }
                return .visitChildren
            }

            override func visit(_ node: BinaryOperatorExprSyntax) -> SyntaxVisitorContinueKind {
                if registrations.contains(where: {
                    $0.name == node.operator.text && $0.kind == .infixOperator
                }) {
                    found = true
                }
                return .skipChildren
            }
        }

        let finder = Finder(registrations: registrations)
        finder.walk(expression)
        return finder.found
    }

    func diagnose(
        _ severity: ConstExprEvaluationEvent.Severity,
        code: String,
        message: String,
        at node: some SyntaxProtocol
    ) {
        guard suppressEvaluationDiagnostics == 0 else { return }
        events.append(
            ConstExprEvaluationEvent(
                severity: severity,
                code: code,
                message: message,
                position: node.positionAfterSkippingLeadingTrivia
            )
        )
    }
}

extension ConstExprLiteralKind {
    var isPolymorphic: Bool {
        switch self {
        case .integer, .floatingPoint, .string, .nilLiteral: true
        case .boolean: false
        }
    }
}
