import Foundation
import SwiftParser
import SwiftParserDiagnostics
import SwiftSyntax

extension ConstExprSourceEvaluator {
    func evaluateCast(
        _ cast: AsExprSyntax,
        depth: Int,
        allowRegisteredCalls: Bool
    ) -> ConstExprEvaluation {
        // Conditional and forced dynamic casts have runtime semantics that the
        // source evaluator cannot prove from syntax alone.
        guard cast.questionOrExclamationMark == nil else {
            return rewriteUnknownChildren(
                ExprSyntax(cast),
                depth: depth,
                allowRegisteredCalls: allowRegisteredCalls
            )
        }
        let expectedTypeName = cast.type.trimmedDescription
        let child = evaluate(
            cast.expression,
            depth: depth + 1,
            allowRegisteredCalls: allowRegisteredCalls,
            expectedTypeName: expectedTypeName
        )
        var rewritten = cast
        rewritten.expression = child.syntax
        guard let value = child.value,
              let converted = staticallyConverted(
                value,
                toSourceType: expectedTypeName
              )
        else {
            return ConstExprEvaluation(syntax: ExprSyntax(rewritten), value: nil)
        }
        return replacement(
            for: converted,
            original: ExprSyntax(cast),
            fallback: ExprSyntax(rewritten)
        )
    }

    func evaluateReference(
        _ reference: DeclReferenceExprSyntax,
        allowRegisteredCalls: Bool
    ) -> ConstExprEvaluation {
        let name = reference.baseName.text
        if let binding = scopes.binding(named: name) {
            switch binding {
            case .unknown:
                return ConstExprEvaluation(
                    syntax: ExprSyntax(reference),
                    value: nil,
                    inferredType: scopes.sourceType(named: name).flatMap(resolvedBuiltinSourceType)
                )
            case .constant(let value):
                return replacement(for: value, original: ExprSyntax(reference), fallback: ExprSyntax(reference))
            }
        }
        guard allowRegisteredCalls else { return .unknown(reference) }
        let registrations = indexedCandidates(named: name, kind: .constant).filter {
            canInvokeRegistration($0) && $0.name == name && $0.kind == .constant
        }
        guard registrations.count == 1 else {
            if registrations.count > 1 {
                diagnose(
                    .warning,
                    code: "ambiguous-constant",
                    message: "constant evaluation found multiple registered constants named '\(name)'",
                    at: reference
                )
            }
            return .unknown(reference)
        }
        do {
            noteThrowingInvocation(registrations[0])
            let value = try registrations[0].invoke()
            return replacement(for: value, original: ExprSyntax(reference), fallback: ExprSyntax(reference))
        } catch {
            diagnose(
                .warning,
                code: "evaluation-threw",
                message: "registered constant threw: \(error)",
                at: reference
            )
            return .unknown(reference)
        }
    }

    // MARK: Calls and member chains

    func evaluateCall(
        _ call: FunctionCallExprSyntax,
        depth: Int,
        allowRegisteredCalls: Bool,
        expectedTypeName: String?
    ) -> ConstExprEvaluation {
        if let expectedTypeName, usesShadowedTypeName(expectedTypeName) {
            return ConstExprEvaluation(syntax: ExprSyntax(call), value: nil)
        }
        if call.trailingClosure != nil || !call.additionalTrailingClosures.isEmpty {
            return rewriteUnknownChildren(
                ExprSyntax(call),
                depth: depth,
                allowRegisteredCalls: allowRegisteredCalls
            )
        }
        if let converted = evaluateBuiltinConversion(
            call,
            depth: depth,
            allowRegisteredCalls: allowRegisteredCalls
        ) {
            return converted
        }
        if let member = call.calledExpression.as(MemberAccessExprSyntax.self),
            let optionalChain = member.base?.as(OptionalChainingExprSyntax.self)
        {
            return evaluateOptionalMemberCall(
                call,
                member: member,
                optionalChain: optionalChain,
                depth: depth,
                allowRegisteredCalls: allowRegisteredCalls,
                expectedTypeName: expectedTypeName
            )
        }

        var rewritten = call
        let labels = call.arguments.map { argument -> String? in
            guard let label = argument.label?.text, label != "_" else { return nil }
            return label
        }
        var receiver: ConstExprValue?
        var candidates: [ConstExprRegistration] = []
        if let member = call.calledExpression.as(MemberAccessExprSyntax.self),
            let base = member.base
        {
            let baseResult = evaluate(
                base,
                depth: depth + 1,
                allowRegisteredCalls: allowRegisteredCalls
            )
            var rewrittenMember = member
            rewrittenMember.base = safeEmbeddedBase(baseResult.syntax, original: base)
            rewritten.calledExpression = ExprSyntax(rewrittenMember)
            receiver = baseResult.value

            if let receiver {
                candidates = registrations(
                    named: member.declName.baseName.text,
                    kind: .instanceMethod,
                    receiverType: receiver.staticType
                )
            } else if let ownerName = qualifiedName(of: base) {
                candidates = registrations(
                    named: member.declName.baseName.text,
                    kind: .staticMethod,
                    ownerName: ownerName
                ) + moduleRegistrations(
                    named: member.declName.baseName.text,
                    moduleName: ownerName,
                    kinds: [.function, .initializer]
                )
                let qualifiedInitializerOwner = "\(ownerName).\(member.declName.baseName.text)"
                let qualifiedInitializers = registrations(
                    named: member.declName.baseName.text,
                    kind: .initializer,
                    ownerName: qualifiedInitializerOwner
                )
                for registration in qualifiedInitializers
                where !candidates.contains(where: {
                    $0.declarationID == registration.declarationID
                }) {
                    candidates.append(registration)
                }
            }
        } else if let member = call.calledExpression.as(MemberAccessExprSyntax.self),
            member.base == nil,
            let expectedTypeName
        {
            // Leading-dot calls have no syntactic owner. Swift resolves both
            // `.init(...)` and contextual factories such as `.library(...)`
            // from the expected result type. Keep every best result match;
            // ordinary argument ranking below must still establish one unique
            // overload or the original spelling is preserved for the compiler.
            candidates = contextualRegistrations(
                named: member.declName.baseName.text,
                kinds: member.declName.baseName.text == "init"
                    ? [.initializer]
                    : [.staticMethod],
                expectedTypeName: expectedTypeName
            )
        } else if let reference = call.calledExpression.as(DeclReferenceExprSyntax.self) {
            let name = reference.baseName.text
            if !scopes.isShadowed(name) {
                candidates = indexedCandidates(named: name).filter {
                    canInvokeRegistration($0)
                        && $0.name == name
                        && ($0.kind == .function || $0.kind == .initializer)
                }
            }
        } else {
            let called = evaluate(
                call.calledExpression,
                depth: depth + 1,
                allowRegisteredCalls: allowRegisteredCalls
            )
            rewritten.calledExpression = called.syntax
        }

        candidates = narrowingRegistrationsByContextualArgumentShape(
            candidates,
            labels: labels,
            arguments: call.arguments
        )

        var argumentValues: [ConstExprValue] = []
        var allArgumentsKnown = true
        var rewrittenArguments: [LabeledExprSyntax] = []
        for (argumentIndex, argument) in call.arguments.enumerated() {
            let result: ConstExprEvaluation
            if let argumentType = agreedArgumentType(
                registrations: candidates,
                labels: labels,
                argumentIndex: argumentIndex
            ), !requiresRuntimeValueWitness(for: argumentType) {
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
                argumentValues.append(value)
            } else {
                allArgumentsKnown = false
            }
        }
        rewritten.arguments = LabeledExprListSyntax(rewrittenArguments)

        guard allArgumentsKnown, !candidates.isEmpty else {
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
            let ranked = viable.compactMap { candidate -> (ViableCall, Int)? in
                guard let rank = expectedResultConversionRank(
                    candidate.registration.resultType,
                    resultDescriptor: candidate.registration.resultTypeDescriptor,
                    expectedSourceName: expectedTypeName
                ) else { return nil }
                return (candidate, rank)
            }
            if let bestRank = ranked.map(\.1).min() {
                viable = ranked.filter { $0.1 == bestRank }.map(\.0)
            } else {
                viable = []
            }
        }
        guard !viable.isEmpty else {
            if allowRegisteredCalls {
                diagnose(
                    .warning,
                    code: "no-matching-overload",
                    message: "no registered overload of this call accepts the constant arguments",
                    at: call
                )
            }
            return ConstExprEvaluation(syntax: ExprSyntax(rewritten), value: nil)
        }
        let best = nonDominated(viable)
        guard best.count == 1 else {
            if allowRegisteredCalls {
                diagnose(
                    .warning,
                    code: "ambiguous-overload",
                    message: "constant evaluation found multiple equally viable overloads",
                    at: call
                )
            }
            return ConstExprEvaluation(syntax: ExprSyntax(rewritten), value: nil)
        }

        guard allowRegisteredCalls else {
            return ConstExprEvaluation(
                syntax: ExprSyntax(rewritten),
                value: nil,
                inferredType: best[0].registration.resultType
            )
        }

        do {
            noteThrowingInvocation(best[0].registration)
            let value = try best[0].registration.invoke(
                receiver: receiver,
                arguments: best[0].arguments
            )
            return replacement(for: value, original: ExprSyntax(call), fallback: ExprSyntax(rewritten))
        } catch {
            diagnose(
                .warning,
                code: "evaluation-threw",
                message: "registered constant expression threw: \(error)",
                at: call
            )
            return ConstExprEvaluation(syntax: ExprSyntax(rewritten), value: nil)
        }
    }

    func evaluateBuiltinConversion(
        _ call: FunctionCallExprSyntax,
        depth: Int,
        allowRegisteredCalls: Bool
    ) -> ConstExprEvaluation? {
        guard let reference = call.calledExpression.as(DeclReferenceExprSyntax.self),
            !scopes.isShadowed(reference.baseName.text),
            let type = builtinType(named: reference.baseName.text),
            call.arguments.count == 1,
            let argument = call.arguments.first,
            argument.label == nil
        else { return nil }
        let result = evaluate(
            argument.expression,
            depth: depth + 1,
            allowRegisteredCalls: allowRegisteredCalls,
            expectedTypeName: isDirectLiteralConversionOperand(argument.expression)
                ? reference.baseName.text
                : nil
        )
        var rewritten = call
        var rewrittenArgument = argument
        rewrittenArgument.expression = result.syntax
        rewritten.arguments = LabeledExprListSyntax([rewrittenArgument])
        guard let value = result.value,
            sameType(value.staticType, type)
                || value.literalConverted(to: type) != nil
        else {
            return ConstExprEvaluation(
                syntax: ExprSyntax(rewritten),
                value: nil,
                inferredType: type
            )
        }
        let converted = sameType(value.staticType, type)
            ? value
            : value.literalConverted(to: type)!
        return replacement(
            for: erasingLiteralProvenance(converted),
            original: ExprSyntax(call),
            fallback: ExprSyntax(rewritten)
        )
    }

    /// Finds leading-dot operations whose owner is supplied solely by a Swift
    /// expected-type context. Result ranking is deliberately only the first
    /// stage: call arguments still pass through the normal overload resolver.
    func contextualRegistrations(
        named name: String,
        kinds: Set<ConstExprRegistrationKind>,
        expectedTypeName: String
    ) -> [ConstExprRegistration] {
        var ownerSourceName = sourceTypeName(expectedTypeName)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while let wrapped = optionalWrappedSourceType(ownerSourceName) {
            ownerSourceName = wrapped
        }
        guard let contextualOwner = runtimeType(matchingSourceName: ownerSourceName) else {
            return []
        }
        let ranked = indexedCandidates(ownerType: contextualOwner).compactMap {
            registration -> (registration: ConstExprRegistration, rank: Int)? in
            guard canInvokeRegistration(registration),
                registration.name == name || (name == "init" && registration.kind == .initializer),
                kinds.contains(registration.kind),
                registration.ownerType.map({ sameType($0, contextualOwner) }) == true,
                let rank = expectedResultConversionRank(
                    registration.resultType,
                    resultDescriptor: registration.resultTypeDescriptor,
                    expectedSourceName: expectedTypeName
                )
            else { return nil }
            return (registration, rank)
        }
        guard let bestRank = ranked.map(\.rank).min() else { return [] }
        return ranked.filter { $0.rank == bestRank }.map(\.registration)
    }

    func isDirectLiteralConversionOperand(_ expression: ExprSyntax) -> Bool {
        if expression.is(IntegerLiteralExprSyntax.self)
            || expression.is(FloatLiteralExprSyntax.self)
            || expression.is(StringLiteralExprSyntax.self)
            || expression.is(BooleanLiteralExprSyntax.self)
        {
            return true
        }
        if let prefix = expression.as(PrefixOperatorExprSyntax.self),
           prefix.operator.text == "+" || prefix.operator.text == "-"
        {
            return isDirectLiteralConversionOperand(prefix.expression)
        }
        if let tuple = expression.as(TupleExprSyntax.self),
           tuple.elements.count == 1,
           tuple.elements.first?.trailingComma == nil,
           let child = tuple.elements.first?.expression
        {
            return isDirectLiteralConversionOperand(child)
        }
        return false
    }
}
