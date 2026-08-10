import Foundation
import SwiftParser
import SwiftParserDiagnostics
import SwiftSyntax

extension ConstExprSourceEvaluator {
    func evaluateDictionary(
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

    func evaluateSubscript(
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

}
