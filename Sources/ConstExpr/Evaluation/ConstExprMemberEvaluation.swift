import Foundation
import SwiftParser
import SwiftParserDiagnostics
import SwiftSyntax

extension ConstExprSourceEvaluator {
    func evaluateOptionalMemberCall(
        _ call: FunctionCallExprSyntax,
        member: MemberAccessExprSyntax,
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
        var rewrittenMember = member
        rewrittenMember.base = ExprSyntax(rewrittenChain)
        var rewritten = call
        rewritten.calledExpression = ExprSyntax(rewrittenMember)

        guard let optional = base.value, optional.isOptional else {
            // The argument expressions are conditionally evaluated at runtime;
            // only syntax-local folding is safe while the receiver is unknown.
            var arguments: [LabeledExprSyntax] = []
            for argument in call.arguments {
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
        let memberName = member.declName.baseName.text
        let labels = call.arguments.map { argument -> String? in
            guard let text = argument.label?.text, text != "_" else { return nil }
            return text
        }
        let candidates = indexedCandidates(named: memberName, kind: .instanceMethod).filter {
            guard canInvokeRegistration($0),
                $0.name == memberName, $0.kind == .instanceMethod,
                let ownerType = $0.ownerType
            else { return false }
            if let wrapped {
                return sameType(wrapped.staticType, ownerType)
            }
            return optional.optionalWraps(ownerType)
        }

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
                original: ExprSyntax(call),
                fallback: ExprSyntax(rewritten)
            )
        }

        var argumentValues: [ConstExprValue] = []
        var rewrittenArguments: [LabeledExprSyntax] = []
        var allArgumentsKnown = true
        for (argumentIndex, argument) in call.arguments.enumerated() {
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
                    allowRegisteredCalls: wrapped != nil && allowRegisteredCalls,
                    expectedTypeName: sourceTypeName(String(reflecting: argumentType))
                )
            } else {
                result = evaluateWithUnknownLiteralContext(
                    argument.expression,
                    depth: depth + 1,
                    allowRegisteredCalls: wrapped != nil && allowRegisteredCalls
                )
            }
            var rewrittenArgument = argument
            rewrittenArgument.expression = result.syntax
            rewrittenArguments.append(rewrittenArgument)
            if let value = result.value {
                argumentValues.append(value)
            } else {
                allArgumentsKnown = false
            }
        }
        rewritten.arguments = LabeledExprListSyntax(rewrittenArguments)
        guard allArgumentsKnown else {
            return ConstExprEvaluation(syntax: ExprSyntax(rewritten), value: nil)
        }

        var viable = candidates.compactMap { registration -> ViableCall? in
            guard let match = match(registration, labels: labels, values: argumentValues) else {
                return nil
            }
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
                optionalResultType($0.registration.resultType, matchesSourceName: expectedTypeName)
            }
        }
        let best = nonDominated(viable)
        guard best.count == 1, let selected = best.first else {
            if allowRegisteredCalls, !viable.isEmpty {
                diagnose(
                    .warning,
                    code: "ambiguous-overload",
                    message: "constant evaluation found multiple equally viable optional member overloads",
                    at: call
                )
            }
            return ConstExprEvaluation(syntax: ExprSyntax(call), value: nil)
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
            let result = try selected.registration.invoke(
                receiver: wrapped,
                arguments: selected.arguments
            )
            let lifted = result.isOptional
                ? result
                : ConstExprValue.optional(
                    result,
                    wrappedType: selected.registration.resultType
                )
            return replacement(for: lifted, original: ExprSyntax(call), fallback: ExprSyntax(rewritten))
        } catch {
            diagnose(
                .warning,
                code: "evaluation-threw",
                message: "registered optional member call threw: \(error)",
                at: call
            )
            return ConstExprEvaluation(syntax: ExprSyntax(rewritten), value: nil)
        }
    }

    func evaluateMember(
        _ member: MemberAccessExprSyntax,
        depth: Int,
        allowRegisteredCalls: Bool,
        expectedTypeName: String?
    ) -> ConstExprEvaluation {
        if allowRegisteredCalls,
           let metatype = evaluateContextualMetatypeLiteral(
               member,
               expectedTypeName: expectedTypeName
           )
        {
            return metatype
        }
        if let optionalChain = member.base?.as(OptionalChainingExprSyntax.self) {
            return evaluateOptionalMemberProperty(
                member,
                optionalChain: optionalChain,
                depth: depth,
                allowRegisteredCalls: allowRegisteredCalls
            )
        }
        guard let base = member.base else {
            guard let expectedTypeName else { return .unknown(member) }
            let candidates = contextualRegistrations(
                named: member.declName.baseName.text,
                kinds: [.staticProperty],
                expectedTypeName: expectedTypeName
            )
            guard allowRegisteredCalls, candidates.count == 1 else {
                if candidates.count > 1 {
                    diagnose(
                        .warning,
                        code: "ambiguous-member",
                        message: "constant evaluation found multiple contextual properties named '\(member.declName.baseName.text)'",
                        at: member
                    )
                }
                return .unknown(member)
            }
            do {
                noteThrowingInvocation(candidates[0])
                let value = try candidates[0].invoke()
                return replacement(
                    for: value,
                    original: ExprSyntax(member),
                    fallback: ExprSyntax(member)
                )
            } catch {
                diagnose(
                    .warning,
                    code: "evaluation-threw",
                    message: "registered contextual property threw: \(error)",
                    at: member
                )
                return .unknown(member)
            }
        }
        let baseResult = evaluate(
            base,
            depth: depth + 1,
            allowRegisteredCalls: allowRegisteredCalls
        )
        var rewritten = member
        rewritten.base = safeEmbeddedBase(baseResult.syntax, original: base)

        var candidates: [ConstExprRegistration] = []
        var receiver: ConstExprValue?
        if let value = baseResult.value {
            if case .tuple(let elements) = value.payload,
               case .tuple = value.staticTypeDescriptor
            {
                let memberName = member.declName.baseName.text
                let tupleValue: ConstExprValue?
                if let index = Int(memberName), elements.indices.contains(index) {
                    tupleValue = elements[index].value
                } else {
                    tupleValue = elements.first { $0.label == memberName }?.value
                }
                if let tupleValue {
                    return replacement(
                        for: tupleValue,
                        original: ExprSyntax(member),
                        fallback: ExprSyntax(rewritten)
                    )
                }
            }
            receiver = value
            candidates = registrations(
                named: member.declName.baseName.text,
                kind: .instanceProperty,
                receiverType: value.staticType
            )
        } else if let ownerName = qualifiedName(of: base) {
            candidates = registrations(
                named: member.declName.baseName.text,
                kind: .staticProperty,
                ownerName: ownerName
            ) + moduleRegistrations(
                named: member.declName.baseName.text,
                moduleName: ownerName,
                kinds: [.constant]
            )
        }

        guard allowRegisteredCalls, candidates.count == 1 else {
            if candidates.count > 1 {
                diagnose(
                    .warning,
                    code: "ambiguous-member",
                    message: "constant evaluation found multiple registered properties named '\(member.declName.baseName.text)'",
                    at: member
                )
            }
            return ConstExprEvaluation(syntax: ExprSyntax(rewritten), value: nil)
        }

        do {
            noteThrowingInvocation(candidates[0])
            let value = try candidates[0].invoke(receiver: receiver, arguments: [])
            return replacement(for: value, original: ExprSyntax(member), fallback: ExprSyntax(rewritten))
        } catch {
            diagnose(
                .warning,
                code: "evaluation-threw",
                message: "registered constant property threw: \(error)",
                at: member
            )
            return ConstExprEvaluation(syntax: ExprSyntax(rewritten), value: nil)
        }
    }

    func evaluateOptionalMemberProperty(
        _ member: MemberAccessExprSyntax,
        optionalChain: OptionalChainingExprSyntax,
        depth: Int,
        allowRegisteredCalls: Bool
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
        var rewritten = member
        rewritten.base = ExprSyntax(rewrittenChain)
        guard let optional = base.value, optional.isOptional else {
            return ConstExprEvaluation(syntax: ExprSyntax(rewritten), value: nil)
        }

        let wrapped = optional.wrappedValue
        let candidates = indexedCandidates(
            named: member.declName.baseName.text,
            kind: .instanceProperty
        ).filter { registration in
            guard canInvokeRegistration(registration),
                registration.name == member.declName.baseName.text,
                registration.kind == .instanceProperty,
                let ownerType = registration.ownerType
            else { return false }
            if let wrapped {
                return sameType(wrapped.staticType, ownerType)
            }
            return optional.optionalWraps(ownerType)
        }
        guard candidates.count == 1, let selected = candidates.first else {
            if allowRegisteredCalls, candidates.count > 1 {
                diagnose(
                    .warning,
                    code: "ambiguous-member",
                    message: "constant evaluation found multiple registered optional properties named '\(member.declName.baseName.text)'",
                    at: member
                )
            }
            return ConstExprEvaluation(syntax: ExprSyntax(rewritten), value: nil)
        }
        guard allowRegisteredCalls else {
            let inferred = ConstExprValue.nilValue(ofOptionalType: selected.resultType)
                ?? .optional(nil, wrappedType: selected.resultType)
            return ConstExprEvaluation(
                syntax: ExprSyntax(rewritten),
                value: nil,
                inferredType: inferred.staticType
            )
        }
        guard let wrapped else {
            let nilValue = ConstExprValue.nilValue(ofOptionalType: selected.resultType)
                ?? .optional(nil, wrappedType: selected.resultType)
            return replacement(
                for: nilValue,
                original: ExprSyntax(member),
                fallback: ExprSyntax(rewritten)
            )
        }
        do {
            noteThrowingInvocation(selected)
            let value = try selected.invoke(receiver: wrapped, arguments: [])
            let lifted = value.isOptional
                ? value
                : ConstExprValue.optional(value, wrappedType: selected.resultType)
            return replacement(
                for: lifted,
                original: ExprSyntax(member),
                fallback: ExprSyntax(rewritten)
            )
        } catch {
            diagnose(
                .warning,
                code: "evaluation-threw",
                message: "registered optional property threw: \(error)",
                at: member
            )
            return ConstExprEvaluation(syntax: ExprSyntax(rewritten), value: nil)
        }
    }

}
