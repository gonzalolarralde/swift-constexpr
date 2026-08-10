import Foundation
import SwiftParser
import SwiftParserDiagnostics
import SwiftSyntax

extension ConstExprSourceEvaluator {
    func evaluatePrefix(
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
        let contextualCandidates = expectedTypeName.map {
            registeredOperatorCandidates(
                named: prefix.operator.text,
                kind: .prefixOperator,
                expectedTypeName: $0
            )
        }
        let registeredOperandType = contextualCandidates.flatMap {
            agreedArgumentType(
                registrations: $0,
                labels: [nil],
                argumentIndex: 0
            )
        }
        let registeredOperandContext = registeredOperandType.flatMap {
            requiresRuntimeValueWitness(for: $0)
                ? nil
                : sourceTypeName(String(reflecting: $0))
        }
        let operandExpectedTypeName: String?
        switch prefix.operator.text {
        case "+", "-", "~", "!":
            operandExpectedTypeName = builtinOperatorOperandContext(expectedTypeName)
                ?? registeredOperandContext
        default:
            // A custom prefix operator's result type need not match its
            // operand type. Use only a parameter type shared by every
            // best-result registered candidate, never the result itself.
            operandExpectedTypeName = registeredOperandContext
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
                allowRegisteredCalls: allowRegisteredCalls,
                candidates: contextualCandidates,
                expectedTypeName: expectedTypeName
            )
        case .failure(let code, let message):
            diagnose(.warning, code: code, message: message, at: prefix)
            return ConstExprEvaluation(syntax: ExprSyntax(rewritten), value: nil)
        }
    }

    func evaluateInfix(
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
        let contextualCandidates = expectedTypeName.map {
            registeredOperatorCandidates(
                named: symbol,
                kind: .infixOperator,
                expectedTypeName: $0
            )
        }
        let labels: [String?] = [nil, nil]
        let registeredLeftType = contextualCandidates.flatMap {
            agreedArgumentType(
                registrations: $0,
                labels: labels,
                argumentIndex: 0
            )
        }
        let registeredRightType = contextualCandidates.flatMap {
            agreedArgumentType(
                registrations: $0,
                labels: labels,
                argumentIndex: 1
            )
        }
        func sourceContext(for type: Any.Type?) -> String? {
            guard let type, !requiresRuntimeValueWitness(for: type) else { return nil }
            return sourceTypeName(String(reflecting: type))
        }
        let builtinOperandContext = infixOperatorPreservesOperandType(symbol)
            ? builtinOperatorOperandContext(expectedTypeName)
            : nil
        let operandExpectedTypeName = builtinOperandContext
            ?? sourceContext(for: registeredLeftType)
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
        } else if let builtinOperandContext {
            rightExpectedTypeName = builtinOperandContext
        } else if let registeredRightContext = sourceContext(for: registeredRightType) {
            rightExpectedTypeName = registeredRightContext
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
                allowRegisteredCalls: allowRegisteredCalls,
                candidates: contextualCandidates,
                expectedTypeName: expectedTypeName
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
                    if contextualCandidates?.isEmpty == false {
                        return evaluateRegisteredOperator(
                            named: symbol,
                            kind: .infixOperator,
                            values: [leftValue, rightValue],
                            original: ExprSyntax(infix),
                            fallback: ExprSyntax(rewritten),
                            allowRegisteredCalls: allowRegisteredCalls,
                            candidates: contextualCandidates,
                            expectedTypeName: expectedTypeName
                        )
                    }
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
                allowRegisteredCalls: allowRegisteredCalls,
                candidates: contextualCandidates,
                expectedTypeName: expectedTypeName
            )
        case .failure(let code, let message):
            if contextualCandidates?.isEmpty == false {
                return evaluateRegisteredOperator(
                    named: symbol,
                    kind: .infixOperator,
                    values: [leftValue, rightValue],
                    original: ExprSyntax(infix),
                    fallback: ExprSyntax(rewritten),
                    allowRegisteredCalls: allowRegisteredCalls,
                    candidates: contextualCandidates,
                    expectedTypeName: expectedTypeName
                )
            }
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

}
