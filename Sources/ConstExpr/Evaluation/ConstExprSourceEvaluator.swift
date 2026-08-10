import Foundation
import SwiftParser
import SwiftParserDiagnostics
import SwiftSyntax

struct ConstExprEvaluation {
    var syntax: ExprSyntax
    var value: ConstExprValue?
    var inferredType: Any.Type? = nil
    var usedDefaultLiteralType = false

    var staticType: Any.Type? {
        value?.staticType ?? inferredType
    }

    static func unknown(_ syntax: some ExprSyntaxProtocol) -> Self {
        Self(syntax: ExprSyntax(syntax), value: nil)
    }
}

struct ConstExprSourceExtensionMember: Hashable {
    var ownerName: String
    var memberName: String
}

struct ConstExprEvaluationEvent {
    enum Severity {
        case note
        case warning
        case error
    }

    var severity: Severity
    var code: String
    var message: String
    var position: AbsolutePosition
}

struct ConstExprResolvedArrayLiteralAdapter {
    let resultTypeDescriptor: ConstExprStaticTypeDescriptor
    let elementType: Any.Type
    let elementTypeDescriptor: ConstExprStaticTypeDescriptor
    let maximumElementCount: Int?
    let invoke: ([ConstExprValue]) throws -> ConstExprValue
}

/// Recursively evaluates an expression exactly once. Unknown parents retain
/// their source while known descendants are still rewritten.
final class ConstExprSourceEvaluator {
    struct ArgumentMappingKey: Hashable {
        let declarationID: String
        let labels: [String?]
    }

    enum CachedArgumentMapping {
        case valid([Int?])
        case invalid
    }

    let registryIndex: ConstExprRegistryIndex
    let registrations: [ConstExprRegistration]
    let typeResolver: ConstExprTypeResolver
    let availabilityContext: ConstExprAvailabilityContext?
    let materializesSource: Bool
    var scopes = ConstExprScopeStack()
    var events: [ConstExprEvaluationEvent] = []
    var evaluatedNodeCount = 0
    var candidateRegistrationCount = 0
    var renderedReplacementCount = 0
    var encounteredUnknownAvailability = false
    var fileDeclaredTypeNames: Set<String> = []
    var sourceExtensionMembers: Set<ConstExprSourceExtensionMember> = []
    var didReportMaximumDepth = false
    var requireExplicitLiteralOperatorContext = 0
    var suppressEvaluationDiagnostics = 0
    var throwingContextDepth = 0
    var locallyHandledThrowingContextDepth = 0
    var throwingInvocationFrames: [Bool] = []
    var argumentMappings: [ArgumentMappingKey: CachedArgumentMapping] = [:]
    /// Catch-bearing `do` statements must retain registered throwing calls.
    /// Folding the last throwing operation can make the `catch` clause
    /// statically unreachable and change whether warning-clean source builds.
    var suppressThrowingRegistrations = 0
    let maximumNodeCount: Int
    let maximumDepth: Int

    init(
        registry: ConstExprRegistry,
        maximumNodeCount: Int,
        maximumDepth: Int,
        availabilityContext: ConstExprAvailabilityContext? = nil,
        materializesSource: Bool = true
    ) {
        let registryIndex = registry.index
        self.registryIndex = registryIndex
        self.registrations = registryIndex.usableRegistrations
        self.typeResolver = ConstExprTypeResolver(index: registryIndex)
        self.availabilityContext = availabilityContext
        self.materializesSource = materializesSource
        self.maximumNodeCount = maximumNodeCount
        self.maximumDepth = maximumDepth
    }

    func evaluate(
        _ expression: ExprSyntax,
        depth: Int = 0,
        allowRegisteredCalls: Bool = true,
        expectedTypeName: String? = nil
    ) -> ConstExprEvaluation {
        guard depth <= maximumDepth else {
            if !didReportMaximumDepth {
                didReportMaximumDepth = true
                diagnose(
                    .warning,
                    code: "maximum-depth",
                    message: "constant evaluation exceeded the maximum depth of \(maximumDepth)",
                    at: expression
                )
            }
            return .unknown(expression)
        }
        guard evaluatedNodeCount < maximumNodeCount else {
            if evaluatedNodeCount == maximumNodeCount {
                diagnose(
                    .warning,
                    code: "maximum-node-count",
                    message: "constant evaluation exceeded the maximum node count of \(maximumNodeCount)",
                    at: expression
                )
                evaluatedNodeCount += 1
            }
            return .unknown(expression)
        }
        evaluatedNodeCount += 1

        if let literal = expression.as(IntegerLiteralExprSyntax.self) {
            if let value = literal.representedLiteralValue {
                return evaluateLiteral(
                    .integerLiteral(value),
                    syntax: expression,
                    allowRegisteredCalls: allowRegisteredCalls,
                    expectedTypeName: expectedTypeName
                )
            }
            if let expectedTypeName,
                let value = fixedWidthIntegerLiteral(
                    literal.literal.text,
                    expectedTypeName: expectedTypeName,
                    isNegative: false
                )
            {
                return replacement(for: value, original: expression, fallback: expression)
            }
        }

        if let literal = expression.as(FloatLiteralExprSyntax.self),
            let value = literal.representedLiteralValue
        {
            return evaluateLiteral(
                .floatingPointLiteral(value),
                syntax: expression,
                allowRegisteredCalls: allowRegisteredCalls,
                expectedTypeName: expectedTypeName
            )
        }

        if let literal = expression.as(BooleanLiteralExprSyntax.self) {
            return evaluateLiteral(
                .booleanLiteral(literal.literal.tokenKind == .keyword(.true)),
                syntax: expression,
                allowRegisteredCalls: allowRegisteredCalls,
                expectedTypeName: expectedTypeName
            )
        }

        if let literal = expression.as(StringLiteralExprSyntax.self),
            let value = literal.representedLiteralValue
        {
            return evaluateLiteral(
                .stringLiteral(value),
                syntax: expression,
                allowRegisteredCalls: allowRegisteredCalls,
                expectedTypeName: expectedTypeName
            )
        }

        if expression.is(NilLiteralExprSyntax.self) {
            return evaluateLiteral(
                .nilLiteral(),
                syntax: expression,
                allowRegisteredCalls: allowRegisteredCalls,
                expectedTypeName: expectedTypeName
            )
        }

        if let cast = expression.as(AsExprSyntax.self) {
            return evaluateCast(
                cast,
                depth: depth,
                allowRegisteredCalls: allowRegisteredCalls
            )
        }

        if let array = expression.as(ArrayExprSyntax.self) {
            return evaluateArray(
                array,
                depth: depth,
                allowRegisteredCalls: allowRegisteredCalls,
                expectedTypeName: expectedTypeName
            )
        }

        if let dictionary = expression.as(DictionaryExprSyntax.self) {
            return evaluateDictionary(
                dictionary,
                depth: depth,
                allowRegisteredCalls: allowRegisteredCalls,
                expectedTypeName: expectedTypeName
            )
        }

        if let reference = expression.as(DeclReferenceExprSyntax.self) {
            return evaluateReference(reference, allowRegisteredCalls: allowRegisteredCalls)
        }

        if let call = expression.as(FunctionCallExprSyntax.self) {
            return evaluateCall(
                call,
                depth: depth,
                allowRegisteredCalls: allowRegisteredCalls,
                expectedTypeName: expectedTypeName
            )
        }

        if let member = expression.as(MemberAccessExprSyntax.self) {
            return evaluateMember(
                member,
                depth: depth,
                allowRegisteredCalls: allowRegisteredCalls,
                expectedTypeName: expectedTypeName
            )
        }

        if let prefix = expression.as(PrefixOperatorExprSyntax.self) {
            return evaluatePrefix(
                prefix,
                depth: depth,
                allowRegisteredCalls: allowRegisteredCalls,
                expectedTypeName: expectedTypeName
            )
        }

        if let postfix = expression.as(PostfixOperatorExprSyntax.self) {
            return evaluatePostfix(
                postfix,
                depth: depth,
                allowRegisteredCalls: allowRegisteredCalls
            )
        }

        if let infix = expression.as(InfixOperatorExprSyntax.self) {
            return evaluateInfix(
                infix,
                depth: depth,
                allowRegisteredCalls: allowRegisteredCalls,
                expectedTypeName: expectedTypeName
            )
        }

        if let ternary = expression.as(TernaryExprSyntax.self) {
            return evaluateTernary(
                ternary,
                depth: depth,
                allowRegisteredCalls: allowRegisteredCalls,
                expectedTypeName: expectedTypeName
            )
        }

        if let tuple = expression.as(TupleExprSyntax.self) {
            return evaluateTuple(
                tuple,
                depth: depth,
                allowRegisteredCalls: allowRegisteredCalls,
                expectedTypeName: expectedTypeName
            )
        }

        if let subscriptCall = expression.as(SubscriptCallExprSyntax.self) {
            return evaluateSubscript(
                subscriptCall,
                depth: depth,
                allowRegisteredCalls: allowRegisteredCalls,
                expectedTypeName: expectedTypeName
            )
        }

        if let optionalChaining = expression.as(OptionalChainingExprSyntax.self) {
            return evaluateOptionalChaining(
                optionalChaining,
                depth: depth,
                allowRegisteredCalls: allowRegisteredCalls
            )
        }

        if let forceUnwrap = expression.as(ForceUnwrapExprSyntax.self) {
            return evaluateForceUnwrap(
                forceUnwrap,
                depth: depth,
                allowRegisteredCalls: allowRegisteredCalls
            )
        }

        if let tryExpression = expression.as(TryExprSyntax.self) {
            let handlesErrorLocally = tryExpression.questionOrExclamationMark != nil
            throwingContextDepth += 1
            throwingInvocationFrames.append(false)
            if handlesErrorLocally { locallyHandledThrowingContextDepth += 1 }
            let child = evaluate(
                tryExpression.expression,
                depth: depth + 1,
                allowRegisteredCalls: allowRegisteredCalls,
                expectedTypeName: expectedTypeName
            )
            if handlesErrorLocally { locallyHandledThrowingContextDepth -= 1 }
            let invokedThrowingRegistration = throwingInvocationFrames.removeLast()
            throwingContextDepth -= 1
            var rewritten = tryExpression
            rewritten.expression = child.syntax
            if let value = child.value {
                guard invokedThrowingRegistration else {
                    // Removing a redundant `try`, `try?`, or `try!` also
                    // removes Swift's diagnostic that no throwing operation
                    // occurs within it. Keep the marker while retaining any
                    // safe child fold.
                    return ConstExprEvaluation(
                        syntax: ExprSyntax(rewritten),
                        value: nil
                    )
                }
                let result: ConstExprValue
                if tryExpression.questionOrExclamationMark?.tokenKind == .postfixQuestionMark {
                    // Since Swift 5, `try?` flattens a value that is already
                    // optional instead of introducing an additional level.
                    result = value.isOptional
                        ? value
                        : .optional(value, wrappedType: value.staticType)
                } else {
                    result = value
                }
                return replacement(
                    for: result,
                    original: ExprSyntax(tryExpression),
                    fallback: ExprSyntax(rewritten)
                )
            }
            return .unknown(rewritten)
        }

        return rewriteUnknownChildren(
            expression,
            depth: depth,
            allowRegisteredCalls: allowRegisteredCalls
        )
    }

    // MARK: Literals and references

}
