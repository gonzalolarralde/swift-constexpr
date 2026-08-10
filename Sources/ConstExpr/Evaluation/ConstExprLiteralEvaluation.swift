import Foundation
import SwiftParser
import SwiftParserDiagnostics
import SwiftSyntax

extension ConstExprSourceEvaluator {
    func evaluateLiteral(
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
    func evaluateRegisteredLiteralConversion(
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

        let candidates = indexedCandidates(ownerType: targetType).filter {
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

    func builtinType(named sourceName: String) -> Any.Type? {
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

    func builtinOptionalWrappedType(named sourceName: String) -> Any.Type? {
        guard !usesShadowedTypeName(sourceName) else { return nil }
        let name = sourceTypeName(sourceName)
        guard name.hasSuffix("?") else { return nil }
        return builtinType(named: String(name.dropLast()))
    }

    func resolvedBuiltinSourceType(named sourceName: String) -> Any.Type? {
        if let type = builtinType(named: sourceName) { return type }
        if let wrapped = builtinOptionalWrappedType(named: sourceName) {
            return ConstExprValue.optional(nil, wrappedType: wrapped).staticType
        }
        return nil
    }

    func fixedWidthIntegerLiteral(
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

    func unsignedIntegerMagnitude(_ tokenText: String) -> UInt64? {
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

    func signedIntegerLiteral<T: FixedWidthInteger & SignedInteger>(
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

    func type(_ type: Any.Type, matchesSourceName sourceName: String) -> Bool {
        guard !usesShadowedTypeName(sourceName) else { return false }
        return typeResolver.type(type, matches: sourceName)
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

    func optionalResultType(_ resultType: Any.Type, matchesSourceName sourceName: String) -> Bool {
        func normalized(_ name: String) -> String {
            sourceTypeName(name).replacingOccurrences(of: " ", with: "")
        }
        return normalized(sourceTypeName(String(reflecting: resultType)) + "?")
            == normalized(sourceName)
    }

    func expectedResultConversionRank(
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

    func runtimeType(matchingSourceName sourceName: String) -> Any.Type? {
        runtimeTypeAndDescriptor(matchingSourceName: sourceName)?.type
    }

    func runtimeTypeAndDescriptor(
        matchingSourceName sourceName: String
    ) -> (type: Any.Type, descriptor: ConstExprStaticTypeDescriptor)? {
        guard !usesShadowedTypeName(sourceName) else { return nil }
        guard let resolved = typeResolver.resolve(sourceName: sourceName),
              let type = resolved.type
        else { return nil }
        return (type, resolved.descriptor)
    }

    func staticTypeContext(
        matchingSourceName sourceName: String
    ) -> (type: Any.Type?, descriptor: ConstExprStaticTypeDescriptor)? {
        guard !usesShadowedTypeName(sourceName) else { return nil }
        guard let resolved = typeResolver.resolve(sourceName: sourceName) else { return nil }
        return (resolved.type, resolved.descriptor)
    }

}
