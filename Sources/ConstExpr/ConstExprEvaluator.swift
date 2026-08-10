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

private struct ConstExprResolvedArrayLiteralAdapter {
    let resultTypeDescriptor: ConstExprStaticTypeDescriptor
    let elementType: Any.Type
    let elementTypeDescriptor: ConstExprStaticTypeDescriptor
    let maximumElementCount: Int?
    let invoke: ([ConstExprValue]) throws -> ConstExprValue
}

/// Recursively evaluates an expression exactly once. Unknown parents retain
/// their source while known descendants are still rewritten.
final class ConstExprSourceEvaluator {
    let registry: ConstExprRegistry
    var scopes = ConstExprScopeStack()
    var events: [ConstExprEvaluationEvent] = []
    var evaluatedNodeCount = 0
    var fileDeclaredTypeNames: Set<String> = []
    var sourceExtensionMembers: Set<ConstExprSourceExtensionMember> = []
    private var didReportMaximumDepth = false
    private var requireExplicitLiteralOperatorContext = 0
    private var suppressEvaluationDiagnostics = 0
    private var throwingContextDepth = 0
    private var locallyHandledThrowingContextDepth = 0
    private var throwingInvocationFrames: [Bool] = []
    /// Catch-bearing `do` statements must retain registered throwing calls.
    /// Folding the last throwing operation can make the `catch` clause
    /// statically unreachable and change whether warning-clean source builds.
    var suppressThrowingRegistrations = 0
    let maximumNodeCount: Int
    let maximumDepth: Int

    init(
        registry: ConstExprRegistry,
        maximumNodeCount: Int,
        maximumDepth: Int
    ) {
        let collidingDeclarationIDs = Set(
            Dictionary(grouping: registry.registrations, by: \.declarationID)
                .filter { $0.value.count > 1 }
                .keys
        )
        self.registry = ConstExprRegistry(
            registrations: registry.registrations.filter {
                $0.isValid && !collidingDeclarationIDs.contains($0.declarationID)
            }
        )
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

    private func evaluateCast(
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

    private func evaluateReference(
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
        let registrations = registry.registrations.filter {
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

    private func evaluateCall(
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
                candidates = registry.registrations.filter {
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

    private func evaluateBuiltinConversion(
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
    private func contextualRegistrations(
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
        let ranked = registry.registrations.compactMap {
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

    private func isDirectLiteralConversionOperand(_ expression: ExprSyntax) -> Bool {
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

    private func evaluateOptionalMemberCall(
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
        let candidates = registry.registrations.filter {
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
                $0.argumentMapping(labels: labels) != nil
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

    private func evaluateMember(
        _ member: MemberAccessExprSyntax,
        depth: Int,
        allowRegisteredCalls: Bool,
        expectedTypeName: String?
    ) -> ConstExprEvaluation {
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

    private func evaluateOptionalMemberProperty(
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
        let candidates = registry.registrations.filter { registration in
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

    private func registrations(
        named name: String,
        kind: ConstExprRegistrationKind,
        receiverType: Any.Type? = nil,
        ownerName: String? = nil
    ) -> [ConstExprRegistration] {
        let matches = registry.registrations.filter { registration in
            guard canInvokeRegistration(registration),
                registration.name == name,
                registration.kind == kind
            else { return false }
            if let receiverType {
                guard let ownerType = registration.ownerType else { return false }
                if sameType(ownerType, receiverType) { return true }
                guard receiverType is AnyClass, ownerType is AnyClass else { return false }
                return isStaticSubtype(receiverType, of: ownerType)
            }
            if let ownerName {
                guard let registeredName = registration.ownerName else { return false }
                if ownerName.contains(".") {
                    return registeredName == ownerName
                        || registeredName.hasSuffix("." + ownerName)
                }
                return registeredName.split(separator: ".").last.map(String.init) == ownerName
            }
            return true
        }
        guard receiverType != nil else { return matches }
        return matches.filter { candidate in
            guard let candidateOwner = candidate.ownerType else { return false }
            return !matches.contains { other in
                guard let otherOwner = other.ownerType,
                      !sameType(otherOwner, candidateOwner)
                else { return false }
                return isStaticSubtype(otherOwner, of: candidateOwner)
                    && !isStaticSubtype(candidateOwner, of: otherOwner)
            }
        }
    }

    private func canInvokeRegistration(_ registration: ConstExprRegistration) -> Bool {
        (!registration.isThrowing
            || (throwingContextDepth > 0
                && (locallyHandledThrowingContextDepth > 0
                    || suppressThrowingRegistrations == 0)))
            && !isShadowedBySourceExtension(registration)
    }

    private func noteThrowingInvocation(_ registration: ConstExprRegistration) {
        guard registration.isThrowing, !throwingInvocationFrames.isEmpty else { return }
        let index = throwingInvocationFrames.index(
            before: throwingInvocationFrames.endIndex
        )
        throwingInvocationFrames[index] = true
    }

    private func isShadowedBySourceExtension(
        _ registration: ConstExprRegistration
    ) -> Bool {
        guard let registeredOwner = registration.ownerName else { return false }
        let memberName = (registration.kind == .initializer
            || registration.kind == .arrayLiteral)
            ? "init"
            : registration.name
        return sourceExtensionMembers.contains { sourceMember in
            guard sourceMember.memberName == memberName else { return false }
            let sourceOwner = sourceMember.ownerName.replacingOccurrences(of: " ", with: "")
            let candidateOwner = registeredOwner.replacingOccurrences(of: " ", with: "")
            if sourceOwner.contains(".") {
                return candidateOwner == sourceOwner
                    || candidateOwner.hasSuffix("." + sourceOwner)
            }
            return candidateOwner.split(separator: ".").last.map(String.init)
                == sourceOwner
        }
    }

    private func moduleRegistrations(
        named name: String,
        moduleName: String,
        kinds: Set<ConstExprRegistrationKind>
    ) -> [ConstExprRegistration] {
        registry.registrations.filter {
            canInvokeRegistration($0)
                && $0.name == name
                && kinds.contains($0.kind)
                && $0.moduleName == moduleName
        }
    }

    private struct CallMatch {
        var arguments: [ConstExprValue?]
        var conversionRanks: [Int]
        var argumentTypes: [Any.Type]
        var argumentDescriptors: [ConstExprStaticTypeDescriptor]
        var sourceTypes: [Any.Type]
        var sourceDescriptors: [ConstExprStaticTypeDescriptor]
        var omittedDefaults: Int
    }

    private struct ViableCall {
        var registration: ConstExprRegistration
        var arguments: [ConstExprValue?]
        var conversionRanks: [Int]
        var argumentTypes: [Any.Type]
        var argumentDescriptors: [ConstExprStaticTypeDescriptor]
        var sourceTypes: [Any.Type]
        var sourceDescriptors: [ConstExprStaticTypeDescriptor]
        var omittedDefaults: Int
    }

    private func match(
        _ registration: ConstExprRegistration,
        labels: [String?],
        values: [ConstExprValue]
    ) -> CallMatch? {
        guard labels.count == values.count else { return nil }
        guard let mapping = registration.argumentMapping(labels: labels) else { return nil }
        var aligned = Array<ConstExprValue?>(repeating: nil, count: registration.parameterTypes.count)
        var conversionRanks = Array(repeating: Int.max, count: values.count)
        var argumentTypes = Array<Any.Type?>(repeating: nil, count: values.count)
        var argumentDescriptors = Array<ConstExprStaticTypeDescriptor?>(
            repeating: nil,
            count: values.count
        )
        for parameterIndex in mapping.indices {
            guard let argumentIndex = mapping[parameterIndex] else { continue }
            let value = values[argumentIndex]
            guard registration.parameterTypeDescriptors.indices.contains(parameterIndex),
                  let rank = self.conversionRank(
                    value,
                    to: registration.parameterTypes[parameterIndex],
                    targetDescriptor: registration.parameterTypeDescriptors[parameterIndex]
                  )
            else {
                return nil
            }
            conversionRanks[argumentIndex] = rank
            argumentTypes[argumentIndex] = registration.parameterTypes[parameterIndex]
            argumentDescriptors[argumentIndex] = registration.parameterTypeDescriptors[parameterIndex]
            aligned[parameterIndex] = value
        }
        guard !conversionRanks.contains(Int.max),
              argumentTypes.allSatisfy({ $0 != nil })
        else { return nil }
        return CallMatch(
            arguments: aligned,
            conversionRanks: conversionRanks,
            argumentTypes: argumentTypes.compactMap { $0 },
            argumentDescriptors: argumentDescriptors.compactMap { $0 },
            sourceTypes: values.map(\.staticType),
            sourceDescriptors: values.map(\.staticTypeDescriptor),
            omittedDefaults: mapping.lazy.filter { $0 == nil }.count
        )
    }

    private func agreedArgumentType(
        registrations: [ConstExprRegistration],
        labels: [String?],
        argumentIndex: Int
    ) -> Any.Type? {
        let types = registrations.compactMap { registration -> Any.Type? in
            guard let mapping = registration.argumentMapping(labels: labels),
                let parameterIndex = mapping.firstIndex(where: { $0 == argumentIndex })
            else { return nil }
            return registration.parameterTypes[parameterIndex]
        }
        guard let first = types.first,
            types.allSatisfy({ sameType($0, first) })
        else { return nil }
        return first
    }

    private func requiresRuntimeValueWitness(for type: Any.Type) -> Bool {
        if type == Any.self { return false }
        if type == AnyObject.self { return true }
        if let wrapped = ConstExprValue.wrappedType(ofOptionalType: type) {
            return requiresRuntimeValueWitness(for: wrapped)
        }
        if let element = ConstExprValue.elementType(ofArrayType: type) {
            return requiresRuntimeValueWitness(for: element)
        }
        if let components = ConstExprValue.keyAndValueTypes(ofDictionaryType: type) {
            return requiresRuntimeValueWitness(for: components.key)
                || requiresRuntimeValueWitness(for: components.value)
        }
        return String(reflecting: Swift.type(of: type)).hasSuffix(".Protocol")
    }

    private func nonDominated(_ candidates: [ViableCall]) -> [ViableCall] {
        candidates.filter { candidate in
            !candidates.contains { other in
                other.registration.declarationID != candidate.registration.declarationID
                    && dominates(other, candidate)
            }
        }
    }

    private func dominates(_ lhs: ViableCall, _ rhs: ViableCall) -> Bool {
        guard lhs.conversionRanks.count == rhs.conversionRanks.count else { return false }
        let pairs = zip(lhs.conversionRanks, rhs.conversionRanks)
        guard pairs.allSatisfy({ $0 <= $1 }) else { return false }
        if zip(lhs.conversionRanks, rhs.conversionRanks).contains(where: { $0 < $1 }) {
            return true
        }
        if lhs.argumentTypes.count == rhs.argumentTypes.count,
           lhs.argumentDescriptors.count == rhs.argumentDescriptors.count
        {
            var foundMoreSpecific = false
            for ((lhsType, rhsType), (lhsDescriptor, rhsDescriptor)) in zip(
                zip(lhs.argumentTypes, rhs.argumentTypes),
                zip(lhs.argumentDescriptors, rhs.argumentDescriptors)
            ) {
                if sameType(lhsType, rhsType) { continue }
                let lhsToRhs = parameterDescriptorConverts(
                    lhsDescriptor,
                    to: rhsDescriptor
                )
                let rhsToLhs = parameterDescriptorConverts(
                    rhsDescriptor,
                    to: lhsDescriptor
                )
                if lhsToRhs, !rhsToLhs {
                    foundMoreSpecific = true
                } else if rhsToLhs, !lhsToRhs {
                    return false
                } else if !lhsToRhs, !rhsToLhs {
                    return false
                }
            }
            if foundMoreSpecific { return true }
        }
        return lhs.omittedDefaults < rhs.omittedDefaults
    }

    /// Models only conversions that establish declaration specificity. A
    /// concrete class conforming to an unrelated protocol is intentionally not
    /// considered more specific than that protocol: Swift treats superclass
    /// and protocol overloads as incomparable for a subclass argument. The
    /// existential witness is used for argument viability, not to invent a
    /// total order between those parameter domains.
    private func parameterDescriptorConverts(
        _ source: ConstExprStaticTypeDescriptor,
        to target: ConstExprStaticTypeDescriptor
    ) -> Bool {
        switch (source, target) {
        case let (
            .leaf(sourceType, _, sourceExistential, sourceClassBound, _),
            .leaf(targetType, _, targetExistential, _, _)
        ):
            if sameType(sourceType, targetType) { return true }
            if targetType == Any.self { return true }
            if targetType == AnyObject.self { return sourceClassBound }
            guard !sourceExistential, !targetExistential else { return false }
            return isStaticSubtype(sourceType, of: targetType)

        case let (.optional(source), .optional(target)):
            return parameterDescriptorConverts(source, to: target)
        case let (.array(source), .array(target)):
            return parameterDescriptorConverts(source, to: target)
        case let (.dictionary(sourceKey, sourceValue), .dictionary(targetKey, targetValue)):
            return parameterDescriptorConverts(sourceKey, to: targetKey)
                && parameterDescriptorConverts(sourceValue, to: targetValue)
        case let (.tuple(source), .tuple(target)) where source.count == target.count:
            return zip(source, target).allSatisfy(parameterDescriptorConverts)
        default:
            return false
        }
    }

    // MARK: Operators

    private func evaluatePrefix(
        _ prefix: PrefixOperatorExprSyntax,
        depth: Int,
        allowRegisteredCalls: Bool,
        expectedTypeName: String?
    ) -> ConstExprEvaluation {
        if let expectedTypeName,
            (prefix.operator.text == "+" || prefix.operator.text == "-"),
            let literal = prefix.expression.as(IntegerLiteralExprSyntax.self),
            let value = fixedWidthIntegerLiteral(
                literal.literal.text,
                expectedTypeName: expectedTypeName,
                isNegative: prefix.operator.text == "-"
            )
        {
            return replacement(for: value, original: ExprSyntax(prefix), fallback: ExprSyntax(prefix))
        }
        let operandExpectedTypeName: String?
        switch prefix.operator.text {
        case "+", "-", "~", "!":
            operandExpectedTypeName = builtinOperatorOperandContext(expectedTypeName)
        default:
            // A custom prefix operator's result type need not match its
            // operand type. Its enclosing result context must not be used to
            // resolve the operand expression.
            operandExpectedTypeName = nil
        }
        let operand = evaluate(
            prefix.expression,
            depth: depth + 1,
            allowRegisteredCalls: allowRegisteredCalls,
            expectedTypeName: operandExpectedTypeName
        )
        var rewritten = prefix
        rewritten.expression = operand.syntax
        guard let value = operand.value else { return .unknown(rewritten) }
        if expectedTypeName == nil,
            requireExplicitLiteralOperatorContext > 0,
            value.literalKind?.isPolymorphic == true
        {
            return ConstExprEvaluation(syntax: ExprSyntax(rewritten), value: nil)
        }

        switch ConstExprOperators.prefix(prefix.operator.text, operand: value) {
        case .value(let result):
            let contextualResult: ConstExprValue
            if let expectedTypeName {
                guard let converted = staticallyConverted(
                    result,
                    toSourceType: expectedTypeName
                ) else {
                    return ConstExprEvaluation(syntax: ExprSyntax(rewritten), value: nil)
                }
                contextualResult = converted
            } else {
                contextualResult = result
            }
            var evaluation = replacement(
                for: contextualResult,
                original: ExprSyntax(prefix),
                fallback: ExprSyntax(rewritten)
            )
            evaluation.usedDefaultLiteralType = expectedTypeName == nil
                && (operand.usedDefaultLiteralType || value.literalKind?.isPolymorphic == true)
            return evaluation
        case .unsupported:
            return evaluateRegisteredOperator(
                named: prefix.operator.text,
                kind: .prefixOperator,
                values: [value],
                original: ExprSyntax(prefix),
                fallback: ExprSyntax(rewritten),
                allowRegisteredCalls: allowRegisteredCalls
            )
        case .failure(let code, let message):
            diagnose(.warning, code: code, message: message, at: prefix)
            return ConstExprEvaluation(syntax: ExprSyntax(rewritten), value: nil)
        }
    }

    private func evaluateInfix(
        _ infix: InfixOperatorExprSyntax,
        depth: Int,
        allowRegisteredCalls: Bool,
        expectedTypeName: String?
    ) -> ConstExprEvaluation {
        if infix.operator.is(AssignmentExprSyntax.self) {
            var rewritten = infix
            let assignmentType = infix.leftOperand.as(DeclReferenceExprSyntax.self).flatMap {
                scopes.sourceType(named: $0.baseName.text)
            }
            if assignmentType != nil {
                rewritten.rightOperand = evaluate(
                    infix.rightOperand,
                    depth: depth + 1,
                    allowRegisteredCalls: allowRegisteredCalls,
                    expectedTypeName: assignmentType
                ).syntax
            } else {
                rewritten.rightOperand = evaluateWithUnknownLiteralContext(
                    infix.rightOperand,
                    depth: depth + 1,
                    allowRegisteredCalls: allowRegisteredCalls
                ).syntax
            }
            return ConstExprEvaluation(syntax: ExprSyntax(rewritten), value: nil)
        }
        guard let binary = infix.operator.as(BinaryOperatorExprSyntax.self) else {
            return rewriteUnknownChildren(ExprSyntax(infix), depth: depth, allowRegisteredCalls: allowRegisteredCalls)
        }
        let symbol = binary.operator.text
        if scopes.isShadowed(symbol) {
            // A source-visible implementation can be selected by result type
            // alone. It is not safe to bypass it with either the stdlib model
            // or a registry adapter that may describe a different overload.
            return ConstExprEvaluation(syntax: ExprSyntax(infix), value: nil)
        }
        if isCompoundAssignmentOperator(symbol) {
            return ConstExprEvaluation(syntax: ExprSyntax(infix), value: nil)
        }
        let operandExpectedTypeName = infixOperatorPreservesOperandType(symbol)
            ? builtinOperatorOperandContext(expectedTypeName)
            : nil
        var left = evaluate(
            infix.leftOperand,
            depth: depth + 1,
            allowRegisteredCalls: allowRegisteredCalls,
            expectedTypeName: operandExpectedTypeName
        )
        var rewritten = infix
        rewritten.leftOperand = left.syntax

        if symbol == "??", let leftValue = left.value,
            case .optional(let wrapped) = leftValue.payload
        {
            if let wrapped {
                let joinSourceName: String?
                if let expectedTypeName {
                    joinSourceName = expectedTypeName
                } else {
                    let wrappedSourceName = leftValue.optionalWrappedType.map {
                        sourceTypeName(String(reflecting: $0))
                    }
                    let rhsExpectedType = containsPotentialRegisteredInvocation(
                        infix.rightOperand
                    ) ? nil : wrappedSourceName
                    let unselected = evaluateSpeculatively(
                        infix.rightOperand,
                        depth: depth + 1,
                        expectedTypeName: rhsExpectedType,
                        requiresExplicitLiteralContext: true
                    )
                    joinSourceName = unselected.staticType.map {
                        sourceTypeName(String(reflecting: $0))
                    } ?? wrappedSourceName
                }
                guard let joinSourceName,
                      let joined = staticallyConverted(
                        wrapped,
                        toSourceType: joinSourceName
                      )
                else {
                    return ConstExprEvaluation(syntax: ExprSyntax(rewritten), value: nil)
                }
                return replacement(
                    for: joined,
                    original: ExprSyntax(infix),
                    fallback: ExprSyntax(rewritten)
                )
            }
            let right = evaluate(
                infix.rightOperand,
                depth: depth + 1,
                allowRegisteredCalls: allowRegisteredCalls,
                expectedTypeName: leftValue.optionalWrappedType.map {
                    sourceTypeName(String(reflecting: $0))
                } ?? expectedTypeName
            )
            rewritten.rightOperand = right.syntax
            if let value = right.value {
                return replacement(for: value, original: ExprSyntax(infix), fallback: ExprSyntax(rewritten))
            }
            return ConstExprEvaluation(syntax: ExprSyntax(rewritten), value: nil)
        }

        if let leftValue = left.value,
            leftValue.staticType == Bool.self,
            let bool = try? leftValue.require(Bool.self)
        {
            if symbol == "&&", !bool {
                let value = ConstExprValue(false)
                if let expectedTypeName {
                    guard let converted = staticallyConverted(
                        value,
                        toSourceType: expectedTypeName
                    ) else {
                        return ConstExprEvaluation(syntax: ExprSyntax(infix), value: nil)
                    }
                    return replacement(
                        for: converted,
                        original: ExprSyntax(infix),
                        fallback: ExprSyntax(rewritten)
                    )
                }
                return replacement(
                    for: value,
                    original: ExprSyntax(infix),
                    fallback: ExprSyntax(rewritten)
                )
            }
            if symbol == "||", bool {
                let value = ConstExprValue(true)
                if let expectedTypeName {
                    guard let converted = staticallyConverted(
                        value,
                        toSourceType: expectedTypeName
                    ) else {
                        return ConstExprEvaluation(syntax: ExprSyntax(infix), value: nil)
                    }
                    return replacement(
                        for: converted,
                        original: ExprSyntax(infix),
                        fallback: ExprSyntax(rewritten)
                    )
                }
                return replacement(
                    for: value,
                    original: ExprSyntax(infix),
                    fallback: ExprSyntax(rewritten)
                )
            }
        }

        let leftIsStructural = left.value.map { value in
            switch value.payload {
            case .optional, .array, .dictionary, .tuple: return true
            case .opaque: return false
            }
        } ?? false
        let rightExpectedTypeName: String?
        if symbol == "<<" || symbol == ">>" {
            rightExpectedTypeName = nil
        } else if let operandExpectedTypeName {
            rightExpectedTypeName = operandExpectedTypeName
        } else if leftIsStructural {
            // Swift may select a common structural element type rather than
            // converting the right operand to the independently inferred left
            // type (`[1] == [1.0]` is a canonical example). Evaluate both
            // sides independently unless an enclosing result context already
            // supplied the shared type.
            rightExpectedTypeName = nil
        } else {
            rightExpectedTypeName = left.staticType.map {
                sourceTypeName(String(reflecting: $0))
            }
        }
        let right = evaluate(
            infix.rightOperand,
            depth: depth + 1,
            allowRegisteredCalls: left.value != nil && allowRegisteredCalls,
            expectedTypeName: rightExpectedTypeName
        )
        rewritten.rightOperand = right.syntax
        if expectedTypeName == nil,
            left.usedDefaultLiteralType,
            let rightType = right.staticType
        {
            if containsPotentialRegisteredInvocation(infix.leftOperand) {
                left = .unknown(infix.leftOperand)
            } else {
                left = evaluate(
                    infix.leftOperand,
                    depth: depth + 1,
                    allowRegisteredCalls: allowRegisteredCalls,
                    expectedTypeName: sourceTypeName(String(reflecting: rightType))
                )
            }
            rewritten.leftOperand = left.syntax
        }
        if expectedTypeName == nil, left.usedDefaultLiteralType, right.value == nil {
            left = .unknown(infix.leftOperand)
            rewritten.leftOperand = infix.leftOperand
        }
        if expectedTypeName == nil, right.usedDefaultLiteralType, left.value == nil {
            rewritten.rightOperand = infix.rightOperand
        }
        guard let leftValue = left.value, let rightValue = right.value else {
            return ConstExprEvaluation(syntax: ExprSyntax(rewritten), value: nil)
        }

        if expectedTypeName == nil,
            requireExplicitLiteralOperatorContext > 0,
            leftValue.literalKind?.isPolymorphic == true
                || rightValue.literalKind?.isPolymorphic == true
        {
            let registered = evaluateRegisteredOperator(
                named: symbol,
                kind: .infixOperator,
                values: [leftValue, rightValue],
                original: ExprSyntax(infix),
                fallback: ExprSyntax(rewritten),
                allowRegisteredCalls: allowRegisteredCalls
            )
            if registered.value != nil { return registered }
            return ConstExprEvaluation(syntax: ExprSyntax(rewritten), value: nil)
        }

        switch ConstExprOperators.infix(symbol, left: leftValue, right: rightValue) {
        case .value(let result):
            let contextualResult: ConstExprValue
            if let expectedTypeName {
                guard let converted = staticallyConverted(
                    result,
                    toSourceType: expectedTypeName
                ) else {
                    return ConstExprEvaluation(syntax: ExprSyntax(rewritten), value: nil)
                }
                contextualResult = converted
            } else {
                contextualResult = result
            }
            var evaluation = replacement(
                for: contextualResult,
                original: ExprSyntax(infix),
                fallback: ExprSyntax(rewritten)
            )
            let resultCanRetainADefaultLiteralType = contextualResult.staticType == Int.self
                || contextualResult.staticType == Double.self
            evaluation.usedDefaultLiteralType = expectedTypeName == nil
                && resultCanRetainADefaultLiteralType
                && (
                    left.usedDefaultLiteralType
                        || right.usedDefaultLiteralType
                        || leftValue.literalKind?.isPolymorphic == true
                        || rightValue.literalKind?.isPolymorphic == true
                )
            return evaluation
        case .unsupported:
            return evaluateRegisteredOperator(
                named: symbol,
                kind: .infixOperator,
                values: [leftValue, rightValue],
                original: ExprSyntax(infix),
                fallback: ExprSyntax(rewritten),
                allowRegisteredCalls: allowRegisteredCalls
            )
        case .failure(let code, let message):
            diagnose(.warning, code: code, message: message, at: infix)
            return ConstExprEvaluation(
                syntax: ExprSyntax(infix),
                value: nil,
                inferredType: sameType(leftValue.staticType, rightValue.staticType)
                    ? leftValue.staticType
                    : nil
            )
        }
    }

    private func isCompoundAssignmentOperator(_ symbol: String) -> Bool {
        guard symbol.hasSuffix("=") else { return false }
        return !["==", "!=", "<=", ">=", "===", "!==", "~="].contains(symbol)
    }

    /// Only operators whose built-in result has the same contextual type as
    /// their operands may inherit a result context. In particular, passing a
    /// `Bool` result context into `lhs == rhs` would incorrectly ask both
    /// operands to resolve as `Bool`.
    private func infixOperatorPreservesOperandType(_ symbol: String) -> Bool {
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
    private func builtinOperatorOperandContext(_ expectedTypeName: String?) -> String? {
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

    private func evaluatePostfix(
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

    private func evaluateTernary(
        _ ternary: TernaryExprSyntax,
        depth: Int,
        allowRegisteredCalls: Bool,
        expectedTypeName: String?
    ) -> ConstExprEvaluation {
        let condition = evaluate(
            ternary.condition,
            depth: depth + 1,
            allowRegisteredCalls: allowRegisteredCalls
        )
        var rewritten = ternary
        rewritten.condition = condition.syntax
        guard let conditionValue = condition.value,
            conditionValue.staticType == Bool.self,
            let flag = try? conditionValue.require(Bool.self)
        else {
            // Preserve laziness: calls in either branch are not executed when
            // the condition cannot be determined.
            let thenResult = evaluateSpeculatively(
                ternary.thenExpression,
                depth: depth + 1,
                expectedTypeName: expectedTypeName,
                requiresExplicitLiteralContext: true
            )
            let elseResult = evaluateSpeculatively(
                ternary.elseExpression,
                depth: depth + 1,
                expectedTypeName: expectedTypeName,
                requiresExplicitLiteralContext: true
            )
            rewritten.thenExpression = thenResult.syntax
            rewritten.elseExpression = elseResult.syntax
            return ConstExprEvaluation(syntax: ExprSyntax(rewritten), value: nil)
        }

        let selectedExpression = flag ? ternary.thenExpression : ternary.elseExpression
        let unselectedExpression = flag ? ternary.elseExpression : ternary.thenExpression
        var result = evaluate(
            selectedExpression,
            depth: depth + 1,
            allowRegisteredCalls: allowRegisteredCalls,
            expectedTypeName: expectedTypeName
        )
        var unselected = evaluateSpeculatively(
            unselectedExpression,
            depth: depth + 1,
            expectedTypeName: expectedTypeName
        )
        if expectedTypeName == nil,
            result.usedDefaultLiteralType,
            let otherType = unselected.staticType
        {
            if containsPotentialRegisteredInvocation(selectedExpression) {
                result = .unknown(selectedExpression)
            } else {
                result = evaluate(
                    selectedExpression,
                    depth: depth + 1,
                    allowRegisteredCalls: allowRegisteredCalls,
                    expectedTypeName: sourceTypeName(String(reflecting: otherType))
                )
            }
        } else if expectedTypeName == nil,
            unselected.usedDefaultLiteralType,
            let selectedType = result.staticType
        {
            unselected = evaluateSpeculatively(
                unselectedExpression,
                depth: depth + 1,
                expectedTypeName: sourceTypeName(String(reflecting: selectedType))
            )
        }
        if flag {
            rewritten.thenExpression = result.syntax
            rewritten.elseExpression = unselected.syntax
        } else {
            rewritten.elseExpression = result.syntax
            rewritten.thenExpression = unselected.syntax
        }
        guard let selectedValue = result.value, let otherType = unselected.staticType else {
            if result.usedDefaultLiteralType {
                if flag { rewritten.thenExpression = selectedExpression }
                else { rewritten.elseExpression = selectedExpression }
            }
            if unselected.usedDefaultLiteralType {
                if flag { rewritten.elseExpression = unselectedExpression }
                else { rewritten.thenExpression = unselectedExpression }
            }
            return ConstExprEvaluation(syntax: ExprSyntax(rewritten), value: nil)
        }

        let finalValue: ConstExprValue?
        if let expectedTypeName,
           let converted = staticallyConverted(
            selectedValue,
            toSourceType: expectedTypeName
           )
        {
            finalValue = converted
        } else if selectedValue.isNil, unselected.value?.isOptional != true {
            finalValue = .optional(nil, wrappedType: otherType)
        } else if unselected.value?.isNil == true, !selectedValue.isOptional {
            finalValue = .optional(selectedValue, wrappedType: selectedValue.staticType)
        } else if selectedValue.isOptional,
            let wrappedType = selectedValue.optionalWrappedType,
            sameType(wrappedType, otherType)
        {
            finalValue = selectedValue
        } else if let otherValue = unselected.value,
            otherValue.isOptional,
            let wrappedType = otherValue.optionalWrappedType,
            sameType(wrappedType, selectedValue.staticType)
        {
            finalValue = .optional(selectedValue, wrappedType: selectedValue.staticType)
        } else if let converted = staticallyConverted(
            selectedValue,
            toSourceType: sourceTypeName(String(reflecting: otherType))
        ) {
            finalValue = converted
        } else if staticConversionRank(
            from: otherType,
            to: selectedValue.staticType
        ) != nil {
            finalValue = selectedValue
        } else if sameType(selectedValue.staticType, otherType) {
            finalValue = selectedValue
        } else {
            finalValue = nil
        }

        guard let finalValue else {
            if result.usedDefaultLiteralType {
                if flag { rewritten.thenExpression = selectedExpression }
                else { rewritten.elseExpression = selectedExpression }
            }
            if unselected.usedDefaultLiteralType {
                if flag { rewritten.elseExpression = unselectedExpression }
                else { rewritten.thenExpression = unselectedExpression }
            }
            return ConstExprEvaluation(syntax: ExprSyntax(rewritten), value: nil)
        }
        return replacement(
            for: finalValue,
            original: ExprSyntax(ternary),
            fallback: ExprSyntax(rewritten)
        )
    }

    private func evaluateTuple(
        _ tuple: TupleExprSyntax,
        depth: Int,
        allowRegisteredCalls: Bool,
        expectedTypeName: String?
    ) -> ConstExprEvaluation {
        var rewritten = tuple
        var rewrittenElements: [LabeledExprSyntax] = []
        var values: [(label: String?, value: ConstExprValue)] = []
        var allKnown = true
        var singleElementUsedDefaultLiteralType = false
        let expectedElementTypes = expectedTypeName.flatMap(tupleSourceTypes).flatMap {
            $0.count == tuple.elements.count ? $0 : nil
        }
        for (index, element) in tuple.elements.enumerated() {
            let result = evaluate(
                element.expression,
                depth: depth + 1,
                allowRegisteredCalls: allowRegisteredCalls,
                expectedTypeName: tuple.elements.count == 1 && element.trailingComma == nil
                    ? expectedTypeName
                    : expectedElementTypes?[index]
            )
            var rewrittenElement = element
            rewrittenElement.expression = result.syntax
            rewrittenElements.append(rewrittenElement)
            if let value = result.value {
                values.append((element.label?.text, value))
            } else {
                allKnown = false
            }
            if tuple.elements.count == 1 {
                singleElementUsedDefaultLiteralType = result.usedDefaultLiteralType
            }
        }
        rewritten.elements = LabeledExprListSyntax(rewrittenElements)

        // Parenthesized expressions are represented as a one-element tuple
        // without a trailing comma.
        if tuple.elements.count == 1,
            tuple.elements.first?.trailingComma == nil,
            let value = values.first?.value
        {
            var evaluation = replacement(
                for: value,
                original: ExprSyntax(tuple),
                fallback: ExprSyntax(rewritten)
            )
            evaluation.usedDefaultLiteralType = singleElementUsedDefaultLiteralType
            return evaluation
        }
        guard allKnown else { return ConstExprEvaluation(syntax: ExprSyntax(rewritten), value: nil) }
        let typeName = "(" + values.map { element in
            let type = element.value.typeName
            return element.label.map { "\($0): \(type)" } ?? type
        }.joined(separator: ", ") + ")"
        return ConstExprEvaluation(
            syntax: ExprSyntax(rewritten),
            value: .tuple(values, typeName: typeName)
        )
    }

    private func evaluateArray(
        _ array: ArrayExprSyntax,
        depth: Int,
        allowRegisteredCalls: Bool,
        expectedTypeName: String?
    ) -> ConstExprEvaluation {
        if let contextual = evaluateContextualArrayLiteral(
            array,
            depth: depth,
            allowRegisteredCalls: allowRegisteredCalls,
            expectedTypeName: expectedTypeName
        ) {
            return contextual
        }

        var rewritten = array
        let originalElements = Array(array.elements)
        var results: [ConstExprEvaluation] = []
        let expectedArrayElementType = expectedTypeName.flatMap(arrayElementSourceType)
        for element in originalElements {
            results.append(evaluate(
                element.expression,
                depth: depth + 1,
                allowRegisteredCalls: allowRegisteredCalls,
                expectedTypeName: expectedArrayElementType
            ))
        }

        let concreteTypes = results.compactMap { result -> Any.Type? in
            guard !result.usedDefaultLiteralType,
                result.value?.literalKind?.isPolymorphic != true
            else { return nil }
            return result.staticType
        }
        if let concreteType = concreteTypes.first,
            concreteTypes.allSatisfy({ sameType($0, concreteType) }),
            results.indices.allSatisfy({
                !results[$0].usedDefaultLiteralType
                    || !containsPotentialRegisteredInvocation(originalElements[$0].expression)
            })
        {
            let expected = sourceTypeName(String(reflecting: concreteType))
            for index in results.indices where results[index].usedDefaultLiteralType {
                results[index] = evaluate(
                    originalElements[index].expression,
                    depth: depth + 1,
                    allowRegisteredCalls: allowRegisteredCalls,
                    expectedTypeName: expected
                )
            }
        }

        var rewrittenElements: [ArrayElementSyntax] = []
        var values: [ConstExprValue] = []
        var allKnown = true
        for (index, element) in originalElements.enumerated() {
            let result = results[index]
            var rewrittenElement = element
            rewrittenElement.expression = result.syntax
            rewrittenElements.append(rewrittenElement)
            if let value = result.value { values.append(value) } else { allKnown = false }
        }
        rewritten.elements = ArrayElementListSyntax(rewrittenElements)
        let knownTypes = Set(values.map(\.typeName))
        if !allKnown || knownTypes.count > 1 {
            // A polymorphic operator may receive element context from a value
            // we could not evaluate. Never leave its default-Int rewrite in a
            // collection whose element type remains unresolved.
            var conservativeElements = rewrittenElements
            for index in results.indices where results[index].usedDefaultLiteralType {
                conservativeElements[index].expression = originalElements[index].expression
            }
            rewritten.elements = ArrayElementListSyntax(conservativeElements)
            guard allKnown, results.allSatisfy({ !$0.usedDefaultLiteralType }) else {
                return ConstExprEvaluation(syntax: ExprSyntax(rewritten), value: nil)
            }
        }
        guard allKnown else { return ConstExprEvaluation(syntax: ExprSyntax(rewritten), value: nil) }
        let elementTypes = Set(values.map(\.typeName))
        let typeName = expectedArrayElementType.map { "[\(sourceTypeName($0))]" }
            ?? (elementTypes.count == 1
                ? "[\(sourceTypeName(elementTypes.first!))]"
                : nil)
        return ConstExprEvaluation(
            syntax: ExprSyntax(rewritten),
            value: .array(values, typeName: typeName)
        )
    }

    /// Evaluates an array literal using either an explicitly registered
    /// user-type adapter or the private unlimited adapter implemented by the
    /// standard `Array` and `Set` types. Returning `nil` means no contextual
    /// adapter exists, so the caller continues with ordinary array inference.
    private func evaluateContextualArrayLiteral(
        _ array: ArrayExprSyntax,
        depth: Int,
        allowRegisteredCalls: Bool,
        expectedTypeName: String?
    ) -> ConstExprEvaluation? {
        guard let expectedTypeName,
              let context = resolvedArrayLiteralAdapters(
                expectedTypeName: expectedTypeName,
                allowRegisteredCalls: allowRegisteredCalls
              )
        else { return nil }

        guard context.adapters.count == 1,
              let adapter = context.adapters.first
        else {
            diagnose(
                .warning,
                code: "ambiguous-overload",
                message: "constant evaluation found multiple array literal adapters for \(context.targetName)",
                at: array
            )
            return ConstExprEvaluation(syntax: ExprSyntax(array), value: nil)
        }
        if let maximum = adapter.maximumElementCount,
           array.elements.count > maximum
        {
            diagnose(
                .warning,
                code: "array-literal-element-limit",
                message: "constant evaluation supports at most \(maximum) elements for \(context.targetName); the compiler will resolve this literal",
                at: array
            )
            return ConstExprEvaluation(syntax: ExprSyntax(array), value: nil)
        }

        let elementSourceName = adapter.elementTypeDescriptor.sourceName
            ?? sourceTypeName(String(reflecting: adapter.elementType))
        var rewritten = array
        var rewrittenElements: [ArrayElementSyntax] = []
        var convertedElements: [ConstExprValue] = []
        var allKnownAndConvertible = true

        for element in array.elements {
            let evaluation = evaluate(
                element.expression,
                depth: depth + 1,
                allowRegisteredCalls: allowRegisteredCalls,
                expectedTypeName: elementSourceName
            )
            var rewrittenElement = element
            rewrittenElement.expression = evaluation.syntax
            rewrittenElements.append(rewrittenElement)

            guard let value = evaluation.value,
                  let converted = try? value.staticallyConverted(
                    to: adapter.elementType,
                    descriptor: adapter.elementTypeDescriptor,
                    sourceTypeName: elementSourceName
                  )
            else {
                allKnownAndConvertible = false
                continue
            }
            convertedElements.append(converted)
        }
        rewritten.elements = ArrayElementListSyntax(rewrittenElements)

        guard allKnownAndConvertible else {
            return ConstExprEvaluation(syntax: ExprSyntax(rewritten), value: nil)
        }

        do {
            let result = try adapter.invoke(convertedElements)
            guard var contextual = try? result.staticallyConverted(
                to: context.targetType,
                descriptor: adapter.resultTypeDescriptor,
                sourceTypeName: context.targetName
            ) else {
                return ConstExprEvaluation(syntax: ExprSyntax(rewritten), value: nil)
            }
            var wrappedType = context.targetType
            for _ in 0..<context.optionalInjectionDepth {
                contextual = .optional(contextual, wrappedType: wrappedType)
                wrappedType = contextual.staticType
            }
            // Array-literal syntax is already the canonical source spelling.
            // Retain it while carrying the exact constructed value into a
            // surrounding registered call or local binding.
            return ConstExprEvaluation(
                syntax: ExprSyntax(rewritten),
                value: contextual
            )
        } catch {
            diagnose(
                .warning,
                code: "evaluation-threw",
                message: "registered array literal adapter failed: \(error)",
                at: array
            )
            return ConstExprEvaluation(syntax: ExprSyntax(rewritten), value: nil)
        }
    }

    private func resolvedArrayLiteralAdapters(
        expectedTypeName: String,
        allowRegisteredCalls: Bool
    ) -> (
        targetName: String,
        targetType: Any.Type,
        optionalInjectionDepth: Int,
        adapters: [ConstExprResolvedArrayLiteralAdapter]
    )? {
        var targetName = sourceTypeName(expectedTypeName)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var optionalInjectionDepth = 0
        while let wrapped = optionalWrappedSourceType(targetName) {
            targetName = wrapped
            optionalInjectionDepth += 1
        }
        guard let targetType = runtimeType(matchingSourceName: targetName),
              let associatedElementType = constExprArrayLiteralElementType(of: targetType)
        else { return nil }

        var adapters: [ConstExprResolvedArrayLiteralAdapter] = []
        if let standardElementType = ConstExprValue.standardArrayLiteralElementType(
            of: targetType
        ),
           sameType(standardElementType, associatedElementType)
        {
            adapters.append(
                ConstExprResolvedArrayLiteralAdapter(
                    resultTypeDescriptor: .inferred(
                        targetType,
                        sourceName: targetName
                    ),
                    elementType: standardElementType,
                    elementTypeDescriptor: .inferred(standardElementType),
                    maximumElementCount: nil,
                    invoke: { elements in
                        guard let value = try ConstExprValue.standardArrayLiteralValue(
                            from: elements,
                            as: targetType,
                            sourceTypeName: targetName
                        ) else {
                            throw ConstExprValueError.typeMismatch(
                                expected: targetName,
                                actual: "array literal"
                            )
                        }
                        return value
                    }
                )
            )
        }

        if allowRegisteredCalls {
            adapters.append(contentsOf: registry.registrations.compactMap { registration in
                guard canInvokeRegistration(registration),
                      registration.kind == .arrayLiteral,
                      registration.ownerType.map({ sameType($0, targetType) }) == true,
                      sameType(registration.resultType, targetType),
                      let elementType = registration.arrayLiteralElementType,
                      sameType(elementType, associatedElementType),
                      let elementDescriptor = registration.arrayLiteralElementTypeDescriptor
                else { return nil }
                return ConstExprResolvedArrayLiteralAdapter(
                    resultTypeDescriptor: registration.resultTypeDescriptor,
                    elementType: elementType,
                    elementTypeDescriptor: elementDescriptor,
                    maximumElementCount: registration.maximumArrayLiteralElementCount,
                    invoke: { elements in
                        try registration.invoke(arguments: elements.map(Optional.some))
                    }
                )
            })
        }
        guard !adapters.isEmpty else { return nil }
        return (targetName, targetType, optionalInjectionDepth, adapters)
    }

    private func evaluateDictionary(
        _ dictionary: DictionaryExprSyntax,
        depth: Int,
        allowRegisteredCalls: Bool,
        expectedTypeName: String?
    ) -> ConstExprEvaluation {
        let expectedComponents = expectedTypeName.flatMap(dictionarySourceTypes)
        guard case .elements(let elements) = dictionary.content else {
            return ConstExprEvaluation(
                syntax: ExprSyntax(dictionary),
                value: .dictionary(
                    [],
                    typeName: expectedComponents.map {
                        "[\(sourceTypeName($0.key)): \(sourceTypeName($0.value))]"
                    }
                )
            )
        }
        let originalElements = Array(elements)
        var rewritten = dictionary
        var rewrittenElements: [DictionaryElementSyntax] = []
        var entries: [(ConstExprValue, ConstExprValue)] = []
        var keyResults: [ConstExprEvaluation] = []
        var valueResults: [ConstExprEvaluation] = []
        var allKnown = true
        for element in originalElements {
            let key = evaluate(
                element.key,
                depth: depth + 1,
                allowRegisteredCalls: allowRegisteredCalls,
                expectedTypeName: expectedComponents?.key
            )
            let value = evaluate(
                element.value,
                depth: depth + 1,
                allowRegisteredCalls: allowRegisteredCalls,
                expectedTypeName: expectedComponents?.value
            )
            keyResults.append(key)
            valueResults.append(value)
            var rewrittenElement = element
            rewrittenElement.key = key.syntax
            rewrittenElement.value = value.syntax
            rewrittenElements.append(rewrittenElement)
            if let keyValue = key.value, let valueValue = value.value {
                entries.append((keyValue, valueValue))
            } else {
                allKnown = false
            }
        }
        rewritten.content = .elements(DictionaryElementListSyntax(rewrittenElements))
        let keyTypesBeforeUnification = Set(entries.map { $0.0.typeName })
        let valueTypesBeforeUnification = Set(entries.map { $0.1.typeName })
        if !allKnown || keyTypesBeforeUnification.count > 1 || valueTypesBeforeUnification.count > 1 {
            var conservativeElements = rewrittenElements
            var restoredDefault = false
            for index in conservativeElements.indices {
                if keyResults[index].usedDefaultLiteralType {
                    conservativeElements[index].key = originalElements[index].key
                    restoredDefault = true
                }
                if valueResults[index].usedDefaultLiteralType {
                    conservativeElements[index].value = originalElements[index].value
                    restoredDefault = true
                }
            }
            rewritten.content = .elements(DictionaryElementListSyntax(conservativeElements))
            if restoredDefault || !allKnown {
                return ConstExprEvaluation(syntax: ExprSyntax(rewritten), value: nil)
            }
        }
        guard allKnown else { return ConstExprEvaluation(syntax: ExprSyntax(rewritten), value: nil) }
        for index in entries.indices {
            guard entries[..<index].contains(where: {
                ConstExprOperators.valuesEqual($0.0, entries[index].0) == true
            }) else { continue }
            diagnose(
                .warning,
                code: "duplicate-dictionary-key",
                message: "dictionary literal contains a duplicate constant key",
                at: dictionary
            )
            return ConstExprEvaluation(syntax: ExprSyntax(rewritten), value: nil)
        }
        let keyTypes = Set(entries.map { $0.0.typeName })
        let valueTypes = Set(entries.map { $0.1.typeName })
        let typeName = expectedComponents.map {
            "[\(sourceTypeName($0.key)): \(sourceTypeName($0.value))]"
        } ?? (keyTypes.count == 1 && valueTypes.count == 1
            ? "[\(sourceTypeName(keyTypes.first!)): \(sourceTypeName(valueTypes.first!))]"
            : nil)
        return ConstExprEvaluation(
            syntax: ExprSyntax(rewritten),
            value: .dictionary(entries, typeName: typeName)
        )
    }

    private func evaluateSubscript(
        _ subscriptCall: SubscriptCallExprSyntax,
        depth: Int,
        allowRegisteredCalls: Bool,
        expectedTypeName: String?
    ) -> ConstExprEvaluation {
        if let optionalChain = subscriptCall.calledExpression.as(OptionalChainingExprSyntax.self) {
            return evaluateOptionalSubscript(
                subscriptCall,
                optionalChain: optionalChain,
                depth: depth,
                allowRegisteredCalls: allowRegisteredCalls,
                expectedTypeName: expectedTypeName
            )
        }
        let base = evaluate(
            subscriptCall.calledExpression,
            depth: depth + 1,
            allowRegisteredCalls: allowRegisteredCalls
        )
        var rewritten = subscriptCall
        rewritten.calledExpression = safeEmbeddedBase(
            base.syntax,
            original: subscriptCall.calledExpression
        )
        let labels = subscriptCall.arguments.map { $0.label?.text }
        let candidates = base.value.map {
            registrations(
                named: "subscript",
                kind: .subscriptGetter,
                receiverType: $0.staticType
            )
        } ?? []
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
            if let value = result.value { values.append(value) } else { allKnown = false }
        }
        rewritten.arguments = LabeledExprListSyntax(rewrittenArguments)
        guard let receiver = base.value, allKnown else {
            return ConstExprEvaluation(syntax: ExprSyntax(rewritten), value: nil)
        }

        if receiver.explicitTypeName != nil,
            case .array(let elements) = receiver.payload,
            values.count == 1,
            let index = try? values[0].require(Int.self)
        {
            guard elements.indices.contains(index) else {
                diagnose(
                    .warning,
                    code: "subscript-out-of-bounds",
                    message: "array index \(index) is out of bounds",
                    at: subscriptCall
                )
                return ConstExprEvaluation(syntax: ExprSyntax(rewritten), value: nil)
            }
            let value = elements[index]
            if let expectedTypeName {
                if let converted = staticallyConverted(value, toSourceType: expectedTypeName) {
                    return replacement(
                        for: converted,
                        original: ExprSyntax(subscriptCall),
                        fallback: ExprSyntax(rewritten)
                    )
                }
            } else {
                return replacement(
                    for: value,
                    original: ExprSyntax(subscriptCall),
                    fallback: ExprSyntax(rewritten)
                )
            }
        }

        if receiver.explicitTypeName != nil,
            case .dictionary(let entries) = receiver.payload,
            values.count == 1
        {
            let matches = entries.filter { ConstExprOperators.valuesEqual($0.0, values[0]) == true }
            if let match = matches.first {
                let optional = ConstExprValue.optional(
                    match.1,
                    wrappedType: match.1.staticType
                )
                if let expectedTypeName {
                    if let converted = staticallyConverted(
                        optional,
                        toSourceType: expectedTypeName
                    ) {
                        return replacement(
                            for: converted,
                            original: ExprSyntax(subscriptCall),
                            fallback: ExprSyntax(rewritten)
                        )
                    }
                } else {
                    return replacement(
                        for: optional,
                        original: ExprSyntax(subscriptCall),
                        fallback: ExprSyntax(rewritten)
                    )
                }
            }
            guard let valueType = entries.first?.1.staticType else {
                return ConstExprEvaluation(syntax: ExprSyntax(rewritten), value: nil)
            }
            let nilValue = ConstExprValue.optional(nil, wrappedType: valueType)
            if let expectedTypeName {
                if let converted = staticallyConverted(
                    nilValue,
                    toSourceType: expectedTypeName
                ) {
                    return replacement(
                        for: converted,
                        original: ExprSyntax(subscriptCall),
                        fallback: ExprSyntax(rewritten)
                    )
                }
            } else {
                return replacement(
                    for: nilValue,
                    original: ExprSyntax(subscriptCall),
                    fallback: ExprSyntax(rewritten)
                )
            }
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
        let best = nonDominated(viable)
        guard allowRegisteredCalls, best.count == 1 else {
            if best.count > 1 {
                diagnose(
                    .warning,
                    code: "ambiguous-overload",
                    message: "constant evaluation found multiple equally viable subscript overloads",
                    at: subscriptCall
                )
            }
            return ConstExprEvaluation(syntax: ExprSyntax(rewritten), value: nil)
        }
        do {
            noteThrowingInvocation(best[0].registration)
            let value = try best[0].registration.invoke(
                receiver: receiver,
                arguments: best[0].arguments
            )
            return replacement(
                for: value,
                original: ExprSyntax(subscriptCall),
                fallback: ExprSyntax(rewritten)
            )
        } catch {
            diagnose(
                .warning,
                code: "evaluation-threw",
                message: "registered constant subscript threw: \(error)",
                at: subscriptCall
            )
            return ConstExprEvaluation(syntax: ExprSyntax(rewritten), value: nil)
        }
    }

    private func evaluateOptionalSubscript(
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
                $0.argumentMapping(labels: labels) != nil
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

    private func evaluateOptionalChaining(
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

    private func evaluateForceUnwrap(
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

    private func evaluateRegisteredOperator(
        named name: String,
        kind: ConstExprRegistrationKind,
        values: [ConstExprValue],
        original: ExprSyntax,
        fallback: ExprSyntax,
        allowRegisteredCalls: Bool
    ) -> ConstExprEvaluation {
        guard allowRegisteredCalls else { return ConstExprEvaluation(syntax: fallback, value: nil) }
        let candidates = registry.registrations.filter {
            canInvokeRegistration($0) && $0.name == name && $0.kind == kind
        }
        let labels = Array<String?>(repeating: nil, count: values.count)
        let viable = candidates.compactMap { registration -> ViableCall? in
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
        let best = nonDominated(viable)
        guard best.count == 1 else {
            if best.count > 1 {
                diagnose(
                    .warning,
                    code: "ambiguous-overload",
                    message: "constant evaluation found multiple custom operator overloads",
                    at: original
                )
            }
            return ConstExprEvaluation(syntax: fallback, value: nil)
        }
        do {
            noteThrowingInvocation(best[0].registration)
            let value = try best[0].registration.invoke(arguments: best[0].arguments)
            return replacement(for: value, original: original, fallback: fallback)
        } catch {
            diagnose(
                .warning,
                code: "evaluation-threw",
                message: "registered constant operator threw: \(error)",
                at: original
            )
            return ConstExprEvaluation(syntax: fallback, value: nil)
        }
    }

    // MARK: Partial rewriting and materialization

    private func rewriteUnknownChildren(
        _ expression: ExprSyntax,
        depth: Int,
        allowRegisteredCalls: Bool
    ) -> ConstExprEvaluation {
        final class ChildRewriter: SyntaxRewriter {
            let evaluator: ConstExprSourceEvaluator
            let depth: Int
            let allowRegisteredCalls: Bool
            var isRoot = true

            init(evaluator: ConstExprSourceEvaluator, depth: Int, allowRegisteredCalls: Bool) {
                self.evaluator = evaluator
                self.depth = depth
                self.allowRegisteredCalls = allowRegisteredCalls
                super.init(viewMode: .sourceAccurate)
            }

            override func visitAny(_ node: Syntax) -> Syntax? {
                if isRoot {
                    isRoot = false
                    return nil
                }
                guard let expression = node.as(ExprSyntax.self) else { return nil }
                return Syntax(
                    evaluator.evaluateWithUnknownLiteralContext(
                        expression,
                        depth: depth + 1,
                        allowRegisteredCalls: allowRegisteredCalls
                    ).syntax
                )
            }
        }

        let rewritten = ChildRewriter(
            evaluator: self,
            depth: depth,
            allowRegisteredCalls: allowRegisteredCalls
        ).rewrite(expression, detach: true).cast(ExprSyntax.self)
        return ConstExprEvaluation(syntax: rewritten, value: nil)
    }

    private func replacement(
        for value: ConstExprValue,
        original: ExprSyntax,
        fallback: ExprSyntax
    ) -> ConstExprEvaluation {
        guard !containsInternalComment(original) else {
            return ConstExprEvaluation(syntax: fallback, value: value)
        }
        guard var expression = render(value) else {
            // Opaque values intentionally flow through registered member chains
            // even though they cannot be emitted as source at this point.
            return ConstExprEvaluation(syntax: fallback, value: value)
        }
        if needsOperatorEmbeddingParentheses(expression, original: original),
            let parenthesized = parenthesizingCompoundExpression(expression)
        {
            expression = parenthesized
        }
        expression.leadingTrivia = original.leadingTrivia
        expression.trailingTrivia = original.trailingTrivia
        return ConstExprEvaluation(syntax: expression, value: value)
    }

    private func containsInternalComment(_ expression: ExprSyntax) -> Bool {
        let tokens = Array(expression.tokens(viewMode: .sourceAccurate))
        guard !tokens.isEmpty else { return false }
        for (index, token) in tokens.enumerated() {
            if index > 0, triviaContainsComment(token.leadingTrivia) { return true }
            if index < tokens.count - 1, triviaContainsComment(token.trailingTrivia) { return true }
        }
        return false
    }

    private func triviaContainsComment(_ trivia: Trivia) -> Bool {
        trivia.pieces.contains { piece in
            switch piece {
            case .blockComment, .docBlockComment, .docLineComment, .lineComment:
                return true
            default:
                return false
            }
        }
    }

    private func render(_ value: ConstExprValue) -> ExprSyntax? {
        if value.isOptional {
            let typeName = sourceTypeName(
                value.explicitTypeName ?? String(reflecting: value.staticType)
            )
            if value.isNil {
                return parseExpression("nil as \(typeName)")
            }
            guard let wrapped = value.wrappedValue,
                let expression = try? wrapped.constExprExpression(
                    contextualizedByOuterType: value.explicitTypeName != nil
                )
            else { return nil }
            return parseExpression("(\(expression.description)) as \(typeName)")
        }
        guard let expression = try? value.constExprExpression(),
            let validated = parseExpression(expression.description)
        else { return nil }
        if isCustomOpaqueValue(value), isCompoundExpression(validated) {
            return parenthesizingCompoundExpression(validated)
        }
        return validated
    }

    private func parenthesizingCompoundExpression(_ expression: ExprSyntax) -> ExprSyntax? {
        guard isCompoundExpression(expression) else { return expression }
        guard var parenthesized = parseExpression("(\(expression.trimmedDescription))") else {
            return nil
        }
        parenthesized.leadingTrivia = expression.leadingTrivia
        parenthesized.trailingTrivia = expression.trailingTrivia
        return parenthesized
    }

    private func isCompoundExpression(_ expression: ExprSyntax) -> Bool {
        expression.is(InfixOperatorExprSyntax.self)
            || expression.is(SequenceExprSyntax.self)
            || expression.is(TernaryExprSyntax.self)
            || expression.is(AssignmentExprSyntax.self)
            || expression.is(AsExprSyntax.self)
    }

    private func needsOperatorEmbeddingParentheses(
        _ rendered: ExprSyntax,
        original: ExprSyntax
    ) -> Bool {
        guard isCompoundExpression(rendered), let parent = original.parent else { return false }
        return parent.is(InfixOperatorExprSyntax.self)
            || parent.is(PrefixOperatorExprSyntax.self)
            || parent.is(PostfixOperatorExprSyntax.self)
    }

    private func isCustomOpaqueValue(_ value: ConstExprValue) -> Bool {
        guard case .opaque = value.payload else { return false }
        let type = value.staticType
        return type != Int.self
            && type != Int8.self
            && type != Int16.self
            && type != Int32.self
            && type != Int64.self
            && type != UInt.self
            && type != UInt8.self
            && type != UInt16.self
            && type != UInt32.self
            && type != UInt64.self
            && type != Float.self
            && type != Double.self
            && type != Bool.self
            && type != String.self
            && type != Character.self
    }

    private func parseExpression(_ source: String) -> ExprSyntax? {
        let file = Parser.parse(source: "let __constant = \(source)")
        guard !ParseDiagnosticsGenerator.diagnostics(for: file).contains(where: {
            $0.diagMessage.severity == .error
        }),
            file.statements.count == 1,
            let declaration = file.statements.first?.item.as(VariableDeclSyntax.self),
            declaration.bindings.count == 1,
            let expression = declaration.bindings.first?.initializer?.value
        else { return nil }
        return expression.detached
    }

    private func safeEmbeddedBase(_ rewritten: ExprSyntax, original: ExprSyntax) -> ExprSyntax {
        guard rewritten.description != original.description,
            !rewritten.is(TupleExprSyntax.self),
            var parenthesized = parseExpression("(\(rewritten.trimmedDescription))")
        else { return rewritten }
        parenthesized.leadingTrivia = rewritten.leadingTrivia
        parenthesized.trailingTrivia = rewritten.trailingTrivia
        return parenthesized
    }

    private func sourceTypeName(_ reflectedName: String) -> String {
        let name = reflectedName.hasPrefix("Swift.")
            ? String(reflectedName.dropFirst("Swift.".count))
            : reflectedName
        if let wrapped = genericArguments(in: name, constructor: "Optional"), wrapped.count == 1 {
            return sourceTypeName(wrapped[0]) + "?"
        }
        if let element = genericArguments(in: name, constructor: "Array"), element.count == 1 {
            return "[\(sourceTypeName(element[0]))]"
        }
        if let arguments = genericArguments(in: name, constructor: "Dictionary"), arguments.count == 2 {
            return "[\(sourceTypeName(arguments[0])): \(sourceTypeName(arguments[1]))]"
        }
        return name
    }

    private func genericArguments(in name: String, constructor: String) -> [String]? {
        let prefix = constructor + "<"
        guard name.hasPrefix(prefix), name.hasSuffix(">") else { return nil }
        let start = name.index(name.startIndex, offsetBy: prefix.count)
        let end = name.index(before: name.endIndex)
        let body = name[start..<end]
        var depth = 0
        var pieceStart = body.startIndex
        var result: [String] = []
        var index = body.startIndex
        while index < body.endIndex {
            switch body[index] {
            case "<", "[", "(": depth += 1
            case ">", "]", ")": depth -= 1
            case "," where depth == 0:
                result.append(String(body[pieceStart..<index]))
                pieceStart = body.index(after: index)
            default: break
            }
            index = body.index(after: index)
        }
        result.append(String(body[pieceStart..<body.endIndex]))
        return result.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private func arrayElementSourceType(_ sourceName: String) -> String? {
        let normalized = sourceTypeName(sourceName).trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.hasPrefix("["), normalized.hasSuffix("]") else { return nil }
        let body = String(normalized.dropFirst().dropLast())
        guard topLevelColon(in: body) == nil else { return nil }
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func setElementSourceType(_ sourceName: String) -> String? {
        let normalized = sourceTypeName(sourceName)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let arguments = genericArguments(in: normalized, constructor: "Set"),
            arguments.count == 1
        else { return nil }
        return arguments[0]
    }

    private func dictionarySourceTypes(_ sourceName: String) -> (key: String, value: String)? {
        let normalized = sourceTypeName(sourceName).trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.hasPrefix("["), normalized.hasSuffix("]") else { return nil }
        let body = String(normalized.dropFirst().dropLast())
        guard let colon = topLevelColon(in: body) else { return nil }
        return (
            String(body[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines),
            String(body[body.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func tupleSourceTypes(_ sourceName: String) -> [String]? {
        let normalized = sourceTypeName(sourceName).trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.hasPrefix("("), normalized.hasSuffix(")") else { return nil }
        let body = String(normalized.dropFirst().dropLast())
        let components = topLevelComponents(in: body)
        guard components.count >= 2 else { return nil }
        return components.map { component in
            guard let colon = topLevelColon(in: component) else {
                return component.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return String(component[component.index(after: colon)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func topLevelComponents(in source: String) -> [String] {
        var depth = 0
        var start = source.startIndex
        var components: [String] = []
        for index in source.indices {
            switch source[index] {
            case "[", "<", "(": depth += 1
            case "]", ">", ")": depth -= 1
            case "," where depth == 0:
                components.append(String(source[start..<index]))
                start = source.index(after: index)
            default: break
            }
        }
        components.append(String(source[start...]))
        return components.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private func topLevelColon(in source: String) -> String.Index? {
        var depth = 0
        for index in source.indices {
            switch source[index] {
            case "[", "<", "(": depth += 1
            case "]", ">", ")": depth -= 1
            case ":" where depth == 0: return index
            default: break
            }
        }
        return nil
    }

    private func evaluateLiteral(
        _ value: ConstExprValue,
        syntax: ExprSyntax,
        allowRegisteredCalls: Bool,
        expectedTypeName: String?
    ) -> ConstExprEvaluation {
        guard let expectedTypeName else {
            return ConstExprEvaluation(syntax: syntax, value: value)
        }
        if let wrappedType = builtinOptionalWrappedType(named: expectedTypeName) {
            let converted: ConstExprValue?
            if value.literalKind == .nilLiteral {
                converted = nil
            } else {
                converted = value.literalConverted(to: wrappedType)
                guard converted != nil else {
                    return ConstExprEvaluation(syntax: syntax, value: value)
                }
            }
            let optional = ConstExprValue.optional(converted, wrappedType: wrappedType)
            return replacement(for: optional, original: syntax, fallback: syntax)
        }
        guard let type = builtinType(named: expectedTypeName),
            let converted = value.literalConverted(to: type)
        else {
            guard allowRegisteredCalls,
                let converted = evaluateRegisteredLiteralConversion(
                    value,
                    syntax: syntax,
                    expectedTypeName: expectedTypeName
                )
            else { return ConstExprEvaluation(syntax: syntax, value: value) }
            return converted
        }
        return replacement(for: converted, original: syntax, fallback: syntax)
    }

    /// Evaluates a user-defined literal conformance through the initializer
    /// adapter that the nominal's `@ConstExpr` peer already registered.
    /// Conformance is checked on the linked result type, so an initializer that
    /// merely happens to use a `stringLiteral:`-style label cannot make invalid
    /// source appear valid. Ambiguous or unsupported witnesses stay untouched.
    private func evaluateRegisteredLiteralConversion(
        _ literal: ConstExprValue,
        syntax: ExprSyntax,
        expectedTypeName: String
    ) -> ConstExprEvaluation? {
        // Literal conversion can inject into Optional, but it cannot guess a
        // concrete conformer from an existential or `Any` expected context.
        var targetName = sourceTypeName(expectedTypeName)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while let wrapped = optionalWrappedSourceType(targetName) {
            targetName = wrapped
        }
        guard let targetType = runtimeType(matchingSourceName: targetName) else {
            return nil
        }

        let label: String
        let associatedLiteralType: Any.Type
        let argument: ConstExprValue
        switch literal.literalKind {
        case .string:
            guard let conforming = targetType as? any ExpressibleByStringLiteral.Type else {
                return nil
            }
            func openString<T: ExpressibleByStringLiteral>(_ type: T.Type) -> Any.Type {
                T.StringLiteralType.self
            }
            label = "stringLiteral"
            associatedLiteralType = _openExistential(conforming, do: openString)
            argument = literal
        case .integer:
            guard let conforming = targetType as? any ExpressibleByIntegerLiteral.Type else {
                return nil
            }
            func openInteger<T: ExpressibleByIntegerLiteral>(_ type: T.Type) -> Any.Type {
                T.IntegerLiteralType.self
            }
            label = "integerLiteral"
            associatedLiteralType = _openExistential(conforming, do: openInteger)
            argument = literal
        case .floatingPoint:
            guard let conforming = targetType as? any ExpressibleByFloatLiteral.Type else {
                return nil
            }
            func openFloat<T: ExpressibleByFloatLiteral>(_ type: T.Type) -> Any.Type {
                T.FloatLiteralType.self
            }
            label = "floatLiteral"
            associatedLiteralType = _openExistential(conforming, do: openFloat)
            argument = literal
        case .boolean:
            guard let conforming = targetType as? any ExpressibleByBooleanLiteral.Type else {
                return nil
            }
            func openBoolean<T: ExpressibleByBooleanLiteral>(_ type: T.Type) -> Any.Type {
                T.BooleanLiteralType.self
            }
            label = "booleanLiteral"
            associatedLiteralType = _openExistential(conforming, do: openBoolean)
            argument = literal
        case .nilLiteral:
            guard targetType is any ExpressibleByNilLiteral.Type else { return nil }
            label = "nilLiteral"
            associatedLiteralType = Void.self
            argument = ConstExprValue(())
        case nil:
            return nil
        }

        let candidates = registry.registrations.filter {
            canInvokeRegistration($0)
                && $0.kind == .initializer
                && $0.ownerType.map { sameType($0, targetType) } == true
                && sameType($0.resultType, targetType)
                && $0.parameterLabels == [label]
                && $0.parameterTypes.count == 1
                && sameType($0.parameterTypes[0], associatedLiteralType)
                && !$0.isThrowing
        }
        let viable = candidates.compactMap { registration -> ViableCall? in
            guard let match = match(
                registration,
                labels: [label],
                values: [argument]
            ) else { return nil }
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
        let best = nonDominated(viable)
        guard best.count == 1 else { return nil }
        do {
            noteThrowingInvocation(best[0].registration)
            let result = try best[0].registration.invoke(
                arguments: best[0].arguments
            )
            guard let contextual = staticallyConverted(
                result,
                toSourceType: expectedTypeName
            ) else { return nil }
            return replacement(
                for: contextual,
                original: syntax,
                fallback: syntax
            )
        } catch {
            diagnose(
                .warning,
                code: "evaluation-threw",
                message: "registered literal initializer threw: \(error)",
                at: syntax
            )
            return nil
        }
    }

    private func builtinType(named sourceName: String) -> Any.Type? {
        guard !usesShadowedTypeName(sourceName) else { return nil }
        let trimmed = sourceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.hasPrefix("Swift.")
            ? String(trimmed.dropFirst("Swift.".count))
            : trimmed
        switch name {
        case "Int": return Int.self
        case "Int8": return Int8.self
        case "Int16": return Int16.self
        case "Int32": return Int32.self
        case "Int64": return Int64.self
        case "UInt": return UInt.self
        case "UInt8": return UInt8.self
        case "UInt16": return UInt16.self
        case "UInt32": return UInt32.self
        case "UInt64": return UInt64.self
        case "Double": return Double.self
        case "Float": return Float.self
        case "String": return String.self
        case "Character": return Character.self
        case "Bool": return Bool.self
        default: return nil
        }
    }

    private func builtinOptionalWrappedType(named sourceName: String) -> Any.Type? {
        guard !usesShadowedTypeName(sourceName) else { return nil }
        let name = sourceTypeName(sourceName)
        guard name.hasSuffix("?") else { return nil }
        return builtinType(named: String(name.dropLast()))
    }

    private func resolvedBuiltinSourceType(named sourceName: String) -> Any.Type? {
        if let type = builtinType(named: sourceName) { return type }
        if let wrapped = builtinOptionalWrappedType(named: sourceName) {
            return ConstExprValue.optional(nil, wrappedType: wrapped).staticType
        }
        return nil
    }

    private func fixedWidthIntegerLiteral(
        _ tokenText: String,
        expectedTypeName: String,
        isNegative: Bool
    ) -> ConstExprValue? {
        guard let magnitude = unsignedIntegerMagnitude(tokenText) else { return nil }
        guard !usesShadowedTypeName(expectedTypeName) else { return nil }
        let trimmed = expectedTypeName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.hasPrefix("Swift.")
            ? String(trimmed.dropFirst("Swift.".count))
            : trimmed
        switch name {
        case "Int": return signedIntegerLiteral(magnitude, negative: isNegative, as: Int.self)
        case "Int8": return signedIntegerLiteral(magnitude, negative: isNegative, as: Int8.self)
        case "Int16": return signedIntegerLiteral(magnitude, negative: isNegative, as: Int16.self)
        case "Int32": return signedIntegerLiteral(magnitude, negative: isNegative, as: Int32.self)
        case "Int64": return signedIntegerLiteral(magnitude, negative: isNegative, as: Int64.self)
        case "UInt" where !isNegative:
            guard let value = UInt(exactly: magnitude) else { return nil }
            return ConstExprValue(value)
        case "UInt8" where !isNegative:
            guard let value = UInt8(exactly: magnitude) else { return nil }
            return ConstExprValue(value)
        case "UInt16" where !isNegative:
            guard let value = UInt16(exactly: magnitude) else { return nil }
            return ConstExprValue(value)
        case "UInt32" where !isNegative:
            guard let value = UInt32(exactly: magnitude) else { return nil }
            return ConstExprValue(value)
        case "UInt64" where !isNegative: return ConstExprValue(magnitude)
        default: return nil
        }
    }

    private func unsignedIntegerMagnitude(_ tokenText: String) -> UInt64? {
        let text = tokenText.replacingOccurrences(of: "_", with: "")
        let radix: Int
        let digits: Substring
        if text.hasPrefix("0x") || text.hasPrefix("0X") {
            radix = 16
            digits = text.dropFirst(2)
        } else if text.hasPrefix("0o") || text.hasPrefix("0O") {
            radix = 8
            digits = text.dropFirst(2)
        } else if text.hasPrefix("0b") || text.hasPrefix("0B") {
            radix = 2
            digits = text.dropFirst(2)
        } else {
            radix = 10
            digits = Substring(text)
        }
        return UInt64(digits, radix: radix)
    }

    private func signedIntegerLiteral<T: FixedWidthInteger & SignedInteger>(
        _ magnitude: UInt64,
        negative: Bool,
        as type: T.Type
    ) -> ConstExprValue? {
        if !negative {
            guard let value = T(exactly: magnitude) else { return nil }
            return ConstExprValue(value)
        }
        let minimumMagnitude = UInt64(T.max) + 1
        if magnitude == minimumMagnitude {
            return ConstExprValue(T.min)
        }
        guard let positive = T(exactly: magnitude) else { return nil }
        return ConstExprValue(-positive)
    }

    private func type(_ type: Any.Type, matchesSourceName sourceName: String) -> Bool {
        guard !usesShadowedTypeName(sourceName) else { return false }
        func normalized(_ name: String) -> String {
            sourceTypeName(name).replacingOccurrences(of: " ", with: "")
        }
        let reflected = normalized(sourceTypeName(String(reflecting: type)))
        let source = normalized(sourceTypeName(sourceName))
        return reflected == source
            || reflected.hasSuffix("." + source)
    }

    func value(_ value: ConstExprValue, matchesSourceType sourceName: String) -> Bool {
        if let explicitTypeName = value.explicitTypeName {
            func normalized(_ name: String) -> String {
                sourceTypeName(name).replacingOccurrences(of: " ", with: "")
            }
            if normalized(explicitTypeName) == normalized(sourceName) { return true }
        }
        return type(value.staticType, matchesSourceName: sourceName)
    }

    private func optionalResultType(_ resultType: Any.Type, matchesSourceName sourceName: String) -> Bool {
        func normalized(_ name: String) -> String {
            sourceTypeName(name).replacingOccurrences(of: " ", with: "")
        }
        return normalized(sourceTypeName(String(reflecting: resultType)) + "?")
            == normalized(sourceName)
    }

    private func expectedResultConversionRank(
        _ resultType: Any.Type,
        resultDescriptor: ConstExprStaticTypeDescriptor,
        expectedSourceName: String
    ) -> Int? {
        if type(resultType, matchesSourceName: expectedSourceName) { return 0 }
        if let expected = runtimeTypeAndDescriptor(matchingSourceName: expectedSourceName),
           let rank = ConstExprStaticTypeDescriptor.conversionRank(
            from: resultDescriptor,
            sourceType: resultType,
            to: expected.descriptor,
            targetType: expected.type
           )
        {
            return rank
        }
        if let expectedType = runtimeType(matchingSourceName: expectedSourceName),
           let rank = staticConversionRank(from: resultType, to: expectedType)
        {
            return rank
        }

        var candidate = sourceTypeName(expectedSourceName)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var optionalInjectionDepth = 0
        while true {
            if type(resultType, matchesSourceName: candidate) {
                return optionalInjectionDepth * 20
            }
            if let expectedType = runtimeType(matchingSourceName: candidate) {
                if isStaticSubtype(resultType, of: expectedType) {
                    return 10 + optionalInjectionDepth * 20
                }
                if expectedType == AnyObject.self, resultType is AnyClass {
                    return 30 + optionalInjectionDepth * 20
                }
                if expectedType == Any.self {
                    return 10 + optionalInjectionDepth * 20
                }
            }
            guard candidate.hasSuffix("?") else { return nil }
            candidate.removeLast()
            candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            optionalInjectionDepth += 1
        }
    }

    private func runtimeType(matchingSourceName sourceName: String) -> Any.Type? {
        runtimeTypeAndDescriptor(matchingSourceName: sourceName)?.type
    }

    private func runtimeTypeAndDescriptor(
        matchingSourceName sourceName: String
    ) -> (type: Any.Type, descriptor: ConstExprStaticTypeDescriptor)? {
        guard !usesShadowedTypeName(sourceName) else { return nil }
        let normalized = sourceTypeName(sourceName)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized == "Any" || normalized == "Swift.Any" {
            return (Any.self, .inferred(Any.self, sourceName: "Any"))
        }
        if normalized == "AnyObject" || normalized == "Swift.AnyObject" {
            return (
                AnyObject.self,
                .inferred(AnyObject.self, sourceName: "AnyObject", isClassBound: true)
            )
        }

        var matches: [(type: Any.Type, descriptor: ConstExprStaticTypeDescriptor)] = []
        for registration in registry.registrations {
            let candidates = Array(zip(
                registration.parameterTypes,
                registration.parameterTypeDescriptors
            )) + [(registration.resultType, registration.resultTypeDescriptor)]
            for candidate in candidates where
                type(candidate.0, matchesSourceName: normalized)
                    || candidate.1.sourceName.map({ sourceTypeName($0) == normalized }) == true
            {
                if let index = matches.firstIndex(where: { sameType($0.type, candidate.0) }) {
                    matches[index].descriptor = .fillingMissingMetadata(
                        from: candidate.1,
                        into: matches[index].descriptor
                    )
                } else {
                    matches.append((candidate.0, candidate.1))
                }
            }
            if let ownerType = registration.ownerType,
               type(ownerType, matchesSourceName: normalized),
               !matches.contains(where: { sameType($0.type, ownerType) })
            {
                matches.append((ownerType, .inferred(ownerType)))
            }
        }
        if matches.count == 1 { return matches[0] }
        guard matches.isEmpty,
              let synthesized = synthesizedTypeContext(matchingSourceName: normalized),
              let type = synthesized.type
        else { return nil }
        return (type, synthesized.descriptor)
    }

    private func staticTypeContext(
        matchingSourceName sourceName: String
    ) -> (type: Any.Type?, descriptor: ConstExprStaticTypeDescriptor)? {
        if let runtime = runtimeTypeAndDescriptor(matchingSourceName: sourceName) {
            return runtime
        }
        return synthesizedTypeContext(matchingSourceName: sourceName)
    }

    private func synthesizedTypeContext(
        matchingSourceName sourceName: String
    ) -> (type: Any.Type?, descriptor: ConstExprStaticTypeDescriptor)? {
        guard !usesShadowedTypeName(sourceName) else { return nil }
        let normalized = sourceTypeName(sourceName)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let builtin = builtinType(named: normalized) {
            return (
                builtin,
                .inferred(builtin, sourceName: normalized)
            )
        }
        if normalized == "Any" {
            return (Any.self, .inferred(Any.self, sourceName: "Any"))
        }
        if normalized == "AnyObject" {
            return (
                AnyObject.self,
                .inferred(AnyObject.self, sourceName: "AnyObject", isClassBound: true)
            )
        }
        if let wrappedName = optionalWrappedSourceType(normalized),
           let wrapped = staticTypeContext(matchingSourceName: wrappedName)
        {
            return (
                wrapped.type.map(optionalMetatype(wrapping:)),
                .optional(wrapped.descriptor)
            )
        }
        if let elementName = arrayElementSourceType(normalized),
           let element = staticTypeContext(matchingSourceName: elementName)
        {
            return (
                element.type.map(arrayMetatype(of:)),
                .array(element.descriptor)
            )
        }
        if let elementName = setElementSourceType(normalized),
           let element = staticTypeContext(matchingSourceName: elementName),
           let elementType = element.type,
           let type = setMetatype(of: elementType)
        {
            return (
                type,
                .inferred(type, sourceName: normalized)
            )
        }
        if let componentNames = dictionarySourceTypes(normalized),
           let key = staticTypeContext(matchingSourceName: componentNames.key),
           let value = staticTypeContext(matchingSourceName: componentNames.value)
        {
            let type = key.type.flatMap { keyType in
                value.type.flatMap { dictionaryMetatype(key: keyType, value: $0) }
            }
            return (
                type,
                .dictionary(key: key.descriptor, value: value.descriptor)
            )
        }
        if let elementNames = tupleSourceTypes(normalized) {
            let elements = elementNames.compactMap(staticTypeContext(matchingSourceName:))
            guard elements.count == elementNames.count else { return nil }
            return (nil, .tuple(elements.map(\.descriptor)))
        }
        return nil
    }

    func staticallyConverted(
        _ value: ConstExprValue,
        toSourceType sourceName: String
    ) -> ConstExprValue? {
        guard let context = staticTypeContext(matchingSourceName: sourceName) else {
            return nil
        }
        return try? value.staticallyConverted(
            to: context.type,
            descriptor: context.descriptor,
            sourceTypeName: sourceTypeName(sourceName)
        )
    }

    private func optionalMetatype(wrapping type: Any.Type) -> Any.Type {
        func open<T>(_ type: T.Type) -> Any.Type { Optional<T>.self }
        return _openExistential(type, do: open)
    }

    private func arrayMetatype(of type: Any.Type) -> Any.Type {
        func open<T>(_ type: T.Type) -> Any.Type { Array<T>.self }
        return _openExistential(type, do: open)
    }

    private func setMetatype(of type: Any.Type) -> Any.Type? {
        guard let hashable = type as? any Hashable.Type else { return nil }
        func open<Element: Hashable>(_ type: Element.Type) -> Any.Type {
            Set<Element>.self
        }
        return _openExistential(hashable, do: open)
    }

    private func dictionaryMetatype(key: Any.Type, value: Any.Type) -> Any.Type? {
        func openKey<Key: Hashable>(_ key: Key.Type) -> Any.Type {
            func openValue<Value>(_ value: Value.Type) -> Any.Type {
                Dictionary<Key, Value>.self
            }
            return _openExistential(value, do: openValue)
        }
        guard let hashableKey = key as? any Hashable.Type else { return nil }
        return _openExistential(hashableKey, do: openKey)
    }

    private func optionalWrappedSourceType(_ sourceName: String) -> String? {
        let normalized = sourceTypeName(sourceName)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.hasSuffix("?") else { return nil }
        var wrapped = String(normalized.dropLast())
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if wrapped.hasPrefix("("), wrapped.hasSuffix(")") {
            wrapped.removeFirst()
            wrapped.removeLast()
        }
        return wrapped
    }

    private func usesShadowedTypeName(_ sourceName: String) -> Bool {
        let source = sourceName.trimmingCharacters(in: .whitespacesAndNewlines)
        if source.hasPrefix("[") {
            if let element = arrayElementSourceType(source) {
                return usesShadowedTypeName(element)
            }
            if let components = dictionarySourceTypes(source) {
                return usesShadowedTypeName(components.key)
                    || usesShadowedTypeName(components.value)
            }
            return false
        }
        if source.hasPrefix("Swift.") {
            return scopes.isShadowed("Swift")
        }
        var candidate = source
        while candidate.hasSuffix("?") {
            candidate.removeLast()
            candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if candidate.hasPrefix("("), candidate.hasSuffix(")") {
            candidate.removeFirst()
            candidate.removeLast()
            candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if candidate.hasPrefix("any ") { candidate.removeFirst(4) }
            if candidate.hasPrefix("some ") { candidate.removeFirst(5) }
            if candidate.contains(",") {
                return topLevelComponents(in: candidate).contains(where: usesShadowedTypeName)
            }
        }
        if candidate.hasPrefix("any ") { candidate.removeFirst(4) }
        if candidate.hasPrefix("some ") { candidate.removeFirst(5) }
        let root = candidate.prefix { character in
            character != "<" && character != "?" && character != "."
                && !character.isWhitespace
        }
        let rootName = String(root)
        if scopes.isShadowed(rootName) || fileDeclaredTypeNames.contains(rootName) {
            return true
        }
        if let arguments = genericArguments(in: candidate, constructor: rootName) {
            return arguments.contains(where: usesShadowedTypeName)
        }
        return false
    }

    private func isStaticSubtype(_ source: Any.Type, of target: Any.Type) -> Bool {
        func opensTarget<T>(_ target: T.Type) -> Bool {
            source is T.Type
        }
        return _openExistential(target, do: opensTarget)
    }

    private func qualifiedName(of expression: ExprSyntax) -> String? {
        if let reference = expression.as(DeclReferenceExprSyntax.self) {
            guard !scopes.isShadowed(reference.baseName.text) else { return nil }
            return reference.baseName.text
        }
        if let member = expression.as(MemberAccessExprSyntax.self),
            let base = member.base,
            let prefix = qualifiedName(of: base)
        {
            return prefix + "." + member.declName.baseName.text
        }
        return nil
    }

    private func sameType(_ lhs: Any.Type, _ rhs: Any.Type) -> Bool {
        ObjectIdentifier(lhs) == ObjectIdentifier(rhs)
    }

    private func conversionRank(
        _ value: ConstExprValue,
        to type: Any.Type,
        targetDescriptor: ConstExprStaticTypeDescriptor? = nil
    ) -> Int? {
        let targetDescriptor = targetDescriptor ?? .inferred(type)
        if sameType(value.staticType, type) { return 0 }
        if value.literalKind == .nilLiteral {
            guard let depth = optionalDepth(of: type) else { return nil }
            return depth * 20
        }
        if let targetWrappedType = ConstExprValue.wrappedType(ofOptionalType: type) {
            let targetWrappedDescriptor: ConstExprStaticTypeDescriptor?
            if case .optional(let wrapped) = targetDescriptor {
                targetWrappedDescriptor = wrapped
            } else {
                targetWrappedDescriptor = nil
            }
            if value.isOptional {
                if let wrapped = value.wrappedValue {
                    return conversionRank(
                        wrapped,
                        to: targetWrappedType,
                        targetDescriptor: targetWrappedDescriptor
                    )
                }
                guard let sourceWrappedType = value.optionalWrappedType else { return nil }
                if let targetWrappedDescriptor,
                   case .optional(let sourceWrappedDescriptor) = value.staticTypeDescriptor,
                   let rank = ConstExprStaticTypeDescriptor.conversionRank(
                    from: sourceWrappedDescriptor,
                    sourceType: sourceWrappedType,
                    to: targetWrappedDescriptor,
                    targetType: targetWrappedType
                   )
                {
                    return rank
                }
                return staticConversionRank(from: sourceWrappedType, to: targetWrappedType)
            }
            guard let wrappedRank = conversionRank(
                value,
                to: targetWrappedType,
                targetDescriptor: targetWrappedDescriptor
            ) else {
                return nil
            }
            return wrappedRank + 20
        }
        if value.literalConverted(to: type) != nil {
            return 100
        }
        if let rank = ConstExprStaticTypeDescriptor.conversionRank(
            from: value.staticTypeDescriptor,
            sourceType: value.staticType,
            to: targetDescriptor,
            targetType: type
        ) {
            return rank
        }
        if value.hasAuthoritativeStaticTypeDescriptor,
           !targetDescriptor.needsRuntimeExistentialWitness
        {
            switch value.payload {
            case .array, .dictionary, .tuple:
                return nil
            default:
                break
            }
        }
        if let rank = staticConversionRank(from: value.staticType, to: type) {
            return rank
        }
        if type == AnyObject.self, value.isStaticallyAnyObject { return 30 }
        if value.provesStaticValueConversion(to: type) { return 10 }
        let targetName = sourceTypeName(String(reflecting: type))
        if self.value(value, matchesSourceType: targetName) { return 0 }
        if let rank = structuralConversionRank(value, toSourceType: targetName) {
            return rank
        }
        return nil
    }

    private func staticConversionRank(from source: Any.Type, to target: Any.Type) -> Int? {
        if sameType(source, target) { return 0 }
        if target == Any.self { return 10 }
        if target == AnyObject.self, source is AnyClass { return 30 }

        if let targetWrapped = ConstExprValue.wrappedType(ofOptionalType: target) {
            if let sourceWrapped = ConstExprValue.wrappedType(ofOptionalType: source) {
                return staticConversionRank(from: sourceWrapped, to: targetWrapped)
            }
            guard let wrappedRank = staticConversionRank(from: source, to: targetWrapped) else {
                return nil
            }
            return wrappedRank + 20
        }

        if let sourceElement = ConstExprValue.elementType(ofArrayType: source),
           let targetElement = ConstExprValue.elementType(ofArrayType: target)
        {
            return staticConversionRank(from: sourceElement, to: targetElement)
        }

        if let sourceTypes = ConstExprValue.keyAndValueTypes(ofDictionaryType: source),
           let targetTypes = ConstExprValue.keyAndValueTypes(ofDictionaryType: target),
           let keyRank = staticConversionRank(from: sourceTypes.key, to: targetTypes.key),
           let valueRank = staticConversionRank(from: sourceTypes.value, to: targetTypes.value)
        {
            return max(keyRank, valueRank)
        }

        if isStaticSubtype(source, of: target) { return 10 }
        return nil
    }

    private func optionalDepth(of type: Any.Type) -> Int? {
        var current = type
        var depth = 0
        while let wrapped = ConstExprValue.wrappedType(ofOptionalType: current) {
            depth += 1
            current = wrapped
        }
        return depth == 0 ? nil : depth
    }

    private func structuralConversionRank(
        _ value: ConstExprValue,
        toSourceType sourceType: String
    ) -> Int? {
        if self.value(value, matchesSourceType: sourceType) { return 0 }

        if let target = builtinType(named: sourceType) {
            if sameType(value.staticType, target) { return 0 }
            guard value.literalConverted(to: target) != nil else { return nil }
            if value.literalKind == .integer, target == Double.self || target == Float.self {
                return 110
            }
            return 100
        }

        if let target = runtimeType(matchingSourceName: sourceType),
           value.provesStaticValueConversion(to: target)
        {
            return 10
        }

        if let elementType = arrayElementSourceType(sourceType),
            case .array(let elements) = value.payload
        {
            if value.hasBoxedRuntimeValue, elements.isEmpty { return nil }
            let ranks = elements.compactMap {
                structuralConversionRank($0, toSourceType: elementType)
            }
            guard ranks.count == elements.count else { return nil }
            return ranks.max() ?? 0
        }

        if let target = dictionarySourceTypes(sourceType),
            case .dictionary(let entries) = value.payload
        {
            if value.hasBoxedRuntimeValue, entries.isEmpty { return nil }
            var ranks: [Int] = []
            for entry in entries {
                guard let keyRank = structuralConversionRank(entry.0, toSourceType: target.key),
                    let valueRank = structuralConversionRank(entry.1, toSourceType: target.value)
                else { return nil }
                ranks.append(keyRank)
                ranks.append(valueRank)
            }
            return ranks.max() ?? 0
        }

        if let targetTypes = tupleSourceTypes(sourceType),
            case .tuple(let elements) = value.payload,
            !value.hasBoxedRuntimeValue,
            (2...4).contains(targetTypes.count),
            targetTypes.count == elements.count
        {
            var ranks: [Int] = []
            for (element, targetType) in zip(elements, targetTypes) {
                guard let rank = structuralConversionRank(
                    element.value,
                    toSourceType: targetType
                ) else { return nil }
                ranks.append(rank)
            }
            return ranks.max() ?? 0
        }

        return nil
    }

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

    private func evaluateSpeculatively(
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

    private func containsPotentialRegisteredInvocation(_ expression: ExprSyntax) -> Bool {
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

        let finder = Finder(registrations: registry.registrations)
        finder.walk(expression)
        return finder.found
    }

    private func diagnose(
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

private extension ConstExprLiteralKind {
    var isPolymorphic: Bool {
        switch self {
        case .integer, .floatingPoint, .string, .nilLiteral: true
        case .boolean: false
        }
    }
}
