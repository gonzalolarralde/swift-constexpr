import Foundation
import SwiftParser
import SwiftParserDiagnostics
import SwiftSyntax

extension ConstExprSourceEvaluator {
    func evaluateOptionalSubscript(
        _ subscriptCall: SubscriptCallExprSyntax,
        optionalChain: OptionalChainingExprSyntax,
        depth: Int,
        allowRegisteredCalls: Bool,
        expectedTypeName: String?
    ) -> ConstExprEvaluation {
        let base = evaluate(
            optionalChain.expression,
            depth: depth + 1,
            allowRegisteredCalls: allowRegisteredCalls
        )
        var rewrittenChain = optionalChain
        rewrittenChain.expression = safeEmbeddedBase(
            base.syntax,
            original: optionalChain.expression
        )
        var rewritten = subscriptCall
        rewritten.calledExpression = ExprSyntax(rewrittenChain)

        guard let optional = base.value, optional.isOptional else {
            var arguments: [LabeledExprSyntax] = []
            for argument in subscriptCall.arguments {
                var argument = argument
                argument.expression = evaluateSpeculatively(
                    argument.expression,
                    depth: depth + 1,
                    expectedTypeName: nil,
                    requiresExplicitLiteralContext: true
                ).syntax
                arguments.append(argument)
            }
            rewritten.arguments = LabeledExprListSyntax(arguments)
            return ConstExprEvaluation(syntax: ExprSyntax(rewritten), value: nil)
        }
        let wrapped = optional.wrappedValue
        let labels = subscriptCall.arguments.map { $0.label?.text }
        let candidates = (wrapped?.staticType ?? optional.optionalWrappedType).map {
            registrations(
                named: "subscript",
                kind: .subscriptGetter,
                receiverType: $0
            )
        } ?? []

        if wrapped == nil {
            var labelCompatible = candidates.filter {
                argumentMapping(for: $0, labels: labels) != nil
            }
            if let expectedTypeName {
                labelCompatible = labelCompatible.filter {
                    optionalResultType($0.resultType, matchesSourceName: expectedTypeName)
                }
            }
            guard labelCompatible.count == 1, let selected = labelCompatible.first else {
                return ConstExprEvaluation(syntax: ExprSyntax(rewritten), value: nil)
            }
            let nilValue = ConstExprValue.nilValue(ofOptionalType: selected.resultType)
                ?? .optional(nil, wrappedType: selected.resultType)
            guard allowRegisteredCalls else {
                return ConstExprEvaluation(
                    syntax: ExprSyntax(rewritten),
                    value: nil,
                    inferredType: nilValue.staticType
                )
            }
            return replacement(
                for: nilValue,
                original: ExprSyntax(subscriptCall),
                fallback: ExprSyntax(rewritten)
            )
        }

        var values: [ConstExprValue] = []
        var rewrittenArguments: [LabeledExprSyntax] = []
        var allKnown = true
        for (argumentIndex, argument) in subscriptCall.arguments.enumerated() {
            let argumentType = agreedArgumentType(
                registrations: candidates,
                labels: labels,
                argumentIndex: argumentIndex
            )
            let result: ConstExprEvaluation
            if let argumentType, !requiresRuntimeValueWitness(for: argumentType) {
                result = evaluate(
                    argument.expression,
                    depth: depth + 1,
                    allowRegisteredCalls: allowRegisteredCalls,
                    expectedTypeName: sourceTypeName(String(reflecting: argumentType))
                )
            } else {
                result = evaluateWithUnknownLiteralContext(
                    argument.expression,
                    depth: depth + 1,
                    allowRegisteredCalls: allowRegisteredCalls
                )
            }
            var rewrittenArgument = argument
            rewrittenArgument.expression = result.syntax
            rewrittenArguments.append(rewrittenArgument)
            if let value = result.value {
                values.append(value)
            } else {
                allKnown = false
            }
        }
        rewritten.arguments = LabeledExprListSyntax(rewrittenArguments)
        guard allKnown else {
            return ConstExprEvaluation(syntax: ExprSyntax(rewritten), value: nil)
        }

        if let wrapped,
            wrapped.explicitTypeName != nil,
            case .array(let elements) = wrapped.payload,
            values.count == 1,
            let index = try? values[0].require(Int.self),
            elements.indices.contains(index)
        {
            let lifted = ConstExprValue.optional(
                elements[index],
                wrappedType: elements[index].staticType
            )
            if let expectedTypeName {
                guard let converted = staticallyConverted(
                    lifted,
                    toSourceType: expectedTypeName
                ) else {
                    return ConstExprEvaluation(syntax: ExprSyntax(rewritten), value: nil)
                }
                return replacement(
                    for: converted,
                    original: ExprSyntax(subscriptCall),
                    fallback: ExprSyntax(rewritten)
                )
            }
            return replacement(
                for: lifted,
                original: ExprSyntax(subscriptCall),
                fallback: ExprSyntax(rewritten)
            )
        }

        var viable = candidates.compactMap { registration -> ViableCall? in
            guard let match = match(registration, labels: labels, values: values) else { return nil }
            return ViableCall(
                registration: registration,
                arguments: match.arguments,
                conversionRanks: match.conversionRanks,
                argumentTypes: match.argumentTypes,
                argumentDescriptors: match.argumentDescriptors,
                sourceTypes: match.sourceTypes,
                sourceDescriptors: match.sourceDescriptors,
                omittedDefaults: match.omittedDefaults
            )
        }
        if let expectedTypeName {
            viable = viable.filter {
                optionalResultType(
                    $0.registration.resultType,
                    matchesSourceName: expectedTypeName
                )
            }
        }
        let best = nonDominated(viable)
        guard best.count == 1, let selected = best.first else {
            if allowRegisteredCalls, best.count > 1 {
                diagnose(
                    .warning,
                    code: "ambiguous-overload",
                    message: "constant evaluation found multiple optional subscript overloads",
                    at: subscriptCall
                )
            }
            return ConstExprEvaluation(syntax: ExprSyntax(rewritten), value: nil)
        }
        guard allowRegisteredCalls else {
            let inferred = ConstExprValue.nilValue(ofOptionalType: selected.registration.resultType)
                ?? .optional(nil, wrappedType: selected.registration.resultType)
            return ConstExprEvaluation(
                syntax: ExprSyntax(rewritten),
                value: nil,
                inferredType: inferred.staticType
            )
        }
        do {
            noteThrowingInvocation(selected.registration)
            let value = try selected.registration.invoke(
                receiver: wrapped,
                arguments: selected.arguments
            )
            let lifted = value.isOptional
                ? value
                : ConstExprValue.optional(
                    value,
                    wrappedType: selected.registration.resultType
                )
            if let expectedTypeName {
                guard let converted = staticallyConverted(
                    lifted,
                    toSourceType: expectedTypeName
                ) else {
                    return ConstExprEvaluation(syntax: ExprSyntax(rewritten), value: nil)
                }
                return replacement(
                    for: converted,
                    original: ExprSyntax(subscriptCall),
                    fallback: ExprSyntax(rewritten)
                )
            }
            return replacement(
                for: lifted,
                original: ExprSyntax(subscriptCall),
                fallback: ExprSyntax(rewritten)
            )
        } catch {
            diagnose(
                .warning,
                code: "evaluation-threw",
                message: "registered optional subscript threw: \(error)",
                at: subscriptCall
            )
            return ConstExprEvaluation(syntax: ExprSyntax(rewritten), value: nil)
        }
    }

    func evaluateOptionalChaining(
        _ optionalChaining: OptionalChainingExprSyntax,
        depth: Int,
        allowRegisteredCalls: Bool
    ) -> ConstExprEvaluation {
        let result = evaluate(
            optionalChaining.expression,
            depth: depth + 1,
            allowRegisteredCalls: allowRegisteredCalls
        )
        var rewritten = optionalChaining
        rewritten.expression = result.syntax
        guard let value = result.value, case .optional(let wrapped) = value.payload else {
            return ConstExprEvaluation(syntax: ExprSyntax(rewritten), value: result.value)
        }
        guard let wrapped else {
            return replacement(for: value, original: ExprSyntax(optionalChaining), fallback: ExprSyntax(rewritten))
        }
        return ConstExprEvaluation(syntax: ExprSyntax(rewritten), value: wrapped)
    }

    func evaluateForceUnwrap(
        _ forceUnwrap: ForceUnwrapExprSyntax,
        depth: Int,
        allowRegisteredCalls: Bool
    ) -> ConstExprEvaluation {
        let result = evaluate(
            forceUnwrap.expression,
            depth: depth + 1,
            allowRegisteredCalls: allowRegisteredCalls
        )
        var rewritten = forceUnwrap
        rewritten.expression = safeEmbeddedBase(
            result.syntax,
            original: forceUnwrap.expression
        )
        guard let value = result.value, case .optional(let wrapped) = value.payload else {
            return ConstExprEvaluation(syntax: ExprSyntax(rewritten), value: nil)
        }
        guard let wrapped else {
            diagnose(
                .warning,
                code: "forced-unwrap-of-nil",
                message: "constant evaluation encountered a forced unwrap of nil",
                at: forceUnwrap
            )
            return ConstExprEvaluation(syntax: ExprSyntax(rewritten), value: nil)
        }
        return replacement(for: wrapped, original: ExprSyntax(forceUnwrap), fallback: ExprSyntax(rewritten))
    }

}
