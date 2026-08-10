import Foundation
import SwiftParser
import SwiftParserDiagnostics
import SwiftSyntax

extension ConstExprSourceEvaluator {
    func evaluateTernary(
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

    func evaluateTuple(
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

}
