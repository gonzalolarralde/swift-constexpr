import Foundation
import SwiftParser
import SwiftParserDiagnostics
import SwiftSyntax

extension ConstExprSourceEvaluator {
    func evaluateArray(
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
    func evaluateContextualArrayLiteral(
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

    func resolvedArrayLiteralAdapters(
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
            adapters.append(contentsOf: indexedArrayLiteralCandidates(
                ownerType: targetType
            ).compactMap { registration in
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

}
