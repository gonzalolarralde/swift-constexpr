import Foundation
import SwiftParser
import SwiftParserDiagnostics
import SwiftSyntax

extension ConstExprSourceEvaluator {
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

    func optionalWrappedSourceType(_ sourceName: String) -> String? {
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

    func usesShadowedTypeName(_ sourceName: String) -> Bool {
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

    func isStaticSubtype(_ source: Any.Type, of target: Any.Type) -> Bool {
        func opensTarget<T>(_ target: T.Type) -> Bool {
            source is T.Type
        }
        return _openExistential(target, do: opensTarget)
    }

    func qualifiedName(of expression: ExprSyntax) -> String? {
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

    func sameType(_ lhs: Any.Type, _ rhs: Any.Type) -> Bool {
        ObjectIdentifier(lhs) == ObjectIdentifier(rhs)
    }

    func conversionRank(
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

    func staticConversionRank(from source: Any.Type, to target: Any.Type) -> Int? {
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

    func optionalDepth(of type: Any.Type) -> Int? {
        var current = type
        var depth = 0
        while let wrapped = ConstExprValue.wrappedType(ofOptionalType: current) {
            depth += 1
            current = wrapped
        }
        return depth == 0 ? nil : depth
    }

    func structuralConversionRank(
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

}
