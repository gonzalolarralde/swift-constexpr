import Foundation

/// Source-static type information used by the evaluator when an erased
/// metatype is not rich enough to describe Swift conversions.
///
/// In particular, an `Any.Type` for a protocol existential cannot tell the
/// evaluator whether the protocol is class-bound or whether another erased
/// source type conforms to it. Macro-generated registrations therefore attach
/// a descriptor (and, for existential leaves, a compiler-checked predicate)
/// to each parameter and result.
public indirect enum ConstExprStaticTypeDescriptor: Sendable {
    public typealias SourceTypePredicate = @Sendable (Any.Type) -> Bool

    case leaf(
        type: Any.Type,
        sourceName: String?,
        isExistential: Bool,
        isClassBound: Bool,
        acceptsSourceType: SourceTypePredicate?
    )
    case optional(Self)
    case array(Self)
    case dictionary(key: Self, value: Self)
    case tuple([Self])

    /// Creates the best descriptor available from runtime metadata alone.
    /// Macro-generated code should spell explicit existential descriptors so
    /// it can supply class-bound and conformance information unavailable from
    /// an erased protocol metatype.
    public static func inferred(
        _ type: Any.Type,
        sourceName: String? = nil,
        isClassBound: Bool? = nil
    ) -> Self {
        if let wrapped = ConstExprValue.wrappedType(ofOptionalType: type) {
            return .optional(.inferred(wrapped))
        }
        if let element = ConstExprValue.elementType(ofArrayType: type) {
            return .array(.inferred(element))
        }
        if let components = ConstExprValue.keyAndValueTypes(ofDictionaryType: type) {
            return .dictionary(
                key: .inferred(components.key),
                value: .inferred(components.value)
            )
        }

        let metatypeKind = String(reflecting: Swift.type(of: type))
        let existential = metatypeKind.hasSuffix(".Protocol")
        return .leaf(
            type: type,
            sourceName: sourceName,
            isExistential: existential,
            isClassBound: isClassBound ?? (type == AnyObject.self || type is AnyClass),
            acceptsSourceType: nil
        )
    }

    public var type: Any.Type? {
        switch self {
        case .leaf(let type, _, _, _, _):
            return type
        case .optional, .array, .dictionary, .tuple:
            // Swift cannot construct an arbitrary tuple metatype from erased
            // element metatypes, and a dictionary key's `Hashable` constraint
            // is likewise erased here. Registrations retain the authoritative
            // top-level metatype alongside this structural shape.
            return nil
        }
    }

    var sourceName: String? {
        switch self {
        case .leaf(_, let sourceName, _, _, _):
            return sourceName
        case .optional(let wrapped):
            guard let wrappedName = wrapped.sourceName else { return nil }
            if case .leaf(_, _, let isExistential, _, _) = wrapped,
               isExistential
            {
                return "(\(wrappedName))?"
            }
            return "\(wrappedName)?"
        case .array(let element):
            return element.sourceName.map { "[\($0)]" }
        case .dictionary(let key, let value):
            guard let key = key.sourceName, let value = value.sourceName else { return nil }
            return "[\(key): \(value)]"
        case .tuple:
            // Element labels are not part of the recursive shape. Preserve the
            // authoritative reflected spelling already carried by a boxed
            // tuple instead of fabricating an unlabeled type.
            return nil
        }
    }

    static func conversionRank(
        from source: Self,
        sourceType: Any.Type? = nil,
        to target: Self,
        targetType: Any.Type? = nil
    ) -> Int? {
        if case .leaf(_, _, let targetIsExistential, _, let accepts) = target,
           targetIsExistential,
           let accepts,
           let sourceType,
           accepts(sourceType)
        {
            return 10
        }
        switch (source, target) {
        case let (
            .leaf(sourceType, _, sourceIsExistential, sourceIsClassBound, _),
            .leaf(targetType, _, targetIsExistential, _, acceptsSourceType)
        ):
            if ObjectIdentifier(sourceType) == ObjectIdentifier(targetType) { return 0 }
            if targetType == Any.self { return 10 }
            if targetType == AnyObject.self {
                return sourceIsClassBound ? 10 : nil
            }
            if targetIsExistential, let acceptsSourceType, acceptsSourceType(sourceType) {
                // Conformance, superclass, and AnyObject conversions are all
                // ordinary non-erasing conversions. Their relative overload
                // specificity is decided from the parameter descriptors, not
                // by imposing a total numeric order here.
                return 10
            }
            if !sourceIsExistential, isStaticSubtype(sourceType, of: targetType) {
                return 10
            }
            return nil

        case let (.optional(sourceWrapped), .optional(targetWrapped)):
            return conversionRank(
                from: sourceWrapped,
                sourceType: sourceType.flatMap(ConstExprValue.wrappedType(ofOptionalType:)),
                to: targetWrapped,
                targetType: targetType.flatMap(ConstExprValue.wrappedType(ofOptionalType:))
            )

        case let (source, .optional(targetWrapped)):
            guard let rank = conversionRank(
                from: source,
                sourceType: sourceType,
                to: targetWrapped,
                targetType: targetType.flatMap(ConstExprValue.wrappedType(ofOptionalType:))
            ) else { return nil }
            return rank + 20

        case let (.array(sourceElement), .array(targetElement)):
            return conversionRank(
                from: sourceElement,
                sourceType: sourceType.flatMap(ConstExprValue.elementType(ofArrayType:)),
                to: targetElement,
                targetType: targetType.flatMap(ConstExprValue.elementType(ofArrayType:))
            )

        case let (
            .dictionary(sourceKey, sourceValue),
            .dictionary(targetKey, targetValue)
        ):
            let sourceComponents = sourceType.flatMap(
                ConstExprValue.keyAndValueTypes(ofDictionaryType:)
            )
            let targetComponents = targetType.flatMap(
                ConstExprValue.keyAndValueTypes(ofDictionaryType:)
            )
            guard let keyRank = conversionRank(
                from: sourceKey,
                sourceType: sourceComponents?.key,
                to: targetKey,
                targetType: targetComponents?.key
            ),
                  let valueRank = conversionRank(
                    from: sourceValue,
                    sourceType: sourceComponents?.value,
                    to: targetValue,
                    targetType: targetComponents?.value
                  )
            else { return nil }
            return max(keyRank, valueRank)

        case let (.tuple(sourceElements), .tuple(targetElements)):
            guard sourceElements.count == targetElements.count else { return nil }
            var labelRank = 0
            if let sourceLabels = reflectedTupleLabels(
                of: sourceType,
                count: sourceElements.count
            ),
               let targetLabels = reflectedTupleLabels(
                of: targetType,
                count: targetElements.count
               )
            {
                for (sourceLabel, targetLabel) in zip(sourceLabels, targetLabels) {
                    if let sourceLabel, let targetLabel {
                        guard sourceLabel == targetLabel else { return nil }
                    } else if sourceLabel != nil || targetLabel != nil {
                        // Adding or erasing a label is permitted, but an exact
                        // tuple-label match is a better overload conversion.
                        labelRank = 1
                    }
                }
            }
            let ranks = zip(sourceElements, targetElements).compactMap {
                conversionRank(from: $0.0, to: $0.1)
            }
            guard ranks.count == sourceElements.count else { return nil }
            return max(ranks.max() ?? 0, labelRank)

        default:
            // Structural value types are ordinary value types. They erase to
            // Any, but never to AnyObject without an explicit bridge whose
            // availability the descriptor does not claim.
            if case .leaf(let targetType, _, _, _, _) = target,
               targetType == Any.self
            {
                return 10
            }
            return nil
        }
    }

    /// Inferred registration descriptors deliberately contain no existential
    /// witness. If a returned value already carries richer metadata for the
    /// exact same source type, retain it. An explicit macro descriptor has a
    /// witness predicate and therefore remains authoritative, including for a
    /// deliberately non-class-bound protocol.
    static func fillingMissingMetadata(from source: Self, into target: Self) -> Self {
        switch (source, target) {
        case let (
            .leaf(sourceType, sourceName, _, sourceClassBound, sourcePredicate),
            .leaf(targetType, targetName, targetExistential, targetClassBound, targetPredicate)
        ) where ObjectIdentifier(sourceType) == ObjectIdentifier(targetType):
            let mayInheritExistentialMetadata = targetExistential && targetPredicate == nil
            return .leaf(
                type: targetType,
                sourceName: targetName ?? sourceName,
                isExistential: targetExistential,
                isClassBound: mayInheritExistentialMetadata
                    ? sourceClassBound
                    : targetClassBound,
                acceptsSourceType: targetPredicate
                    ?? (mayInheritExistentialMetadata ? sourcePredicate : nil)
            )
        case let (.optional(source), .optional(target)):
            return .optional(fillingMissingMetadata(from: source, into: target))
        case let (.array(source), .array(target)):
            return .array(fillingMissingMetadata(from: source, into: target))
        case let (.dictionary(sourceKey, sourceValue), .dictionary(targetKey, targetValue)):
            return .dictionary(
                key: fillingMissingMetadata(from: sourceKey, into: targetKey),
                value: fillingMissingMetadata(from: sourceValue, into: targetValue)
            )
        case let (.tuple(source), .tuple(target)) where source.count == target.count:
            return .tuple(zip(source, target).map(fillingMissingMetadata(from:into:)))
        default:
            return target
        }
    }

    func matches(type: Any.Type) -> Bool {
        switch self {
        case .leaf(let describedType, _, _, _, _):
            return ObjectIdentifier(describedType) == ObjectIdentifier(type)
        case .optional(let wrapped):
            guard let wrappedType = ConstExprValue.wrappedType(ofOptionalType: type) else {
                return false
            }
            return wrapped.matches(type: wrappedType)
        case .array(let element):
            guard let elementType = ConstExprValue.elementType(ofArrayType: type) else {
                return false
            }
            return element.matches(type: elementType)
        case .dictionary(let key, let value):
            guard let types = ConstExprValue.keyAndValueTypes(ofDictionaryType: type) else {
                return false
            }
            return key.matches(type: types.key) && value.matches(type: types.value)
        case .tuple(let elements):
            let reflected = String(reflecting: type)
            guard elements.count >= 2 else { return false }
            return matches(reflectedType: reflected)
        }
    }

    /// Validates recursive tuple metadata from the canonical reflected type
    /// spelling. Swift does not expose a general erased tuple-metatype opener,
    /// but its reflection spelling is balanced and sufficient to reject a
    /// descriptor with the wrong arity or element types before invocation.
    private func matches(reflectedType spelling: String) -> Bool {
        switch self {
        case .leaf(let type, _, _, _, _):
            return normalizedTypeSpelling(String(reflecting: type))
                == normalizedTypeSpelling(spelling)
        case .optional(let wrapped):
            guard let arguments = genericArguments(
                in: spelling,
                constructors: ["Optional", "Swift.Optional"]
            ), arguments.count == 1 else { return false }
            return wrapped.matches(reflectedType: arguments[0])
        case .array(let element):
            guard let arguments = genericArguments(
                in: spelling,
                constructors: ["Array", "Swift.Array"]
            ), arguments.count == 1 else { return false }
            return element.matches(reflectedType: arguments[0])
        case .dictionary(let key, let value):
            guard let arguments = genericArguments(
                in: spelling,
                constructors: ["Dictionary", "Swift.Dictionary"]
            ), arguments.count == 2 else { return false }
            return key.matches(reflectedType: arguments[0])
                && value.matches(reflectedType: arguments[1])
        case .tuple(let elements):
            let source = spelling.trimmingCharacters(in: .whitespacesAndNewlines)
            guard source.first == "(", source.last == ")" else { return false }
            let body = String(source.dropFirst().dropLast())
            let components = topLevelComponents(in: body).map(removingTupleLabel)
            guard components.count == elements.count else { return false }
            return zip(elements, components).allSatisfy {
                $0.0.matches(reflectedType: $0.1)
            }
        }
    }

    private func genericArguments(
        in spelling: String,
        constructors: Set<String>
    ) -> [String]? {
        let source = spelling.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let opening = source.firstIndex(of: "<"), source.last == ">" else { return nil }
        let constructor = source[..<opening].trimmingCharacters(in: .whitespacesAndNewlines)
        guard constructors.contains(constructor) else { return nil }
        return topLevelComponents(in: String(source[source.index(after: opening)..<source.index(before: source.endIndex)]))
    }

    private func topLevelComponents(in source: String) -> [String] {
        var result: [String] = []
        var start = source.startIndex
        var depth = 0
        for index in source.indices {
            switch source[index] {
            case "(", "[", "<": depth += 1
            case ")", "]", ">": depth -= 1
            case "," where depth == 0:
                result.append(String(source[start..<index]).trimmingCharacters(in: .whitespacesAndNewlines))
                start = source.index(after: index)
            default: break
            }
        }
        result.append(String(source[start...]).trimmingCharacters(in: .whitespacesAndNewlines))
        return result
    }

    private func removingTupleLabel(_ source: String) -> String {
        var depth = 0
        for index in source.indices {
            switch source[index] {
            case "(", "[", "<": depth += 1
            case ")", "]", ">": depth -= 1
            case ":" where depth == 0:
                return String(source[source.index(after: index)...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            default: break
            }
        }
        return source.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizedTypeSpelling(_ source: String) -> String {
        source.filter { !$0.isWhitespace }
    }

    var needsRuntimeExistentialWitness: Bool {
        switch self {
        case .leaf(_, _, let isExistential, _, let predicate):
            return isExistential && predicate == nil
        case .optional(let wrapped), .array(let wrapped):
            return wrapped.needsRuntimeExistentialWitness
        case .dictionary(let key, let value):
            return key.needsRuntimeExistentialWitness
                || value.needsRuntimeExistentialWitness
        case .tuple(let elements):
            return elements.contains(where: \.needsRuntimeExistentialWitness)
        }
    }

    private static func isStaticSubtype(_ source: Any.Type, of target: Any.Type) -> Bool {
        func opensTarget<T>(_ target: T.Type) -> Bool {
            source is T.Type
        }
        return _openExistential(target, do: opensTarget)
    }

    private static func reflectedTupleLabels(
        of type: Any.Type?,
        count: Int
    ) -> [String?]? {
        guard let type else { return nil }
        let reflected = String(reflecting: type)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard reflected.first == "(", reflected.last == ")" else { return nil }
        let body = String(reflected.dropFirst().dropLast())
        var components: [String] = []
        var start = body.startIndex
        var depth = 0
        for index in body.indices {
            switch body[index] {
            case "(", "[", "<": depth += 1
            case ")", "]", ">": depth -= 1
            case "," where depth == 0:
                components.append(String(body[start..<index]))
                start = body.index(after: index)
            default: break
            }
        }
        components.append(String(body[start...]))
        guard components.count == count else { return nil }
        return components.map { component in
            var depth = 0
            for index in component.indices {
                switch component[index] {
                case "(", "[", "<": depth += 1
                case ")", "]", ">": depth -= 1
                case ":" where depth == 0:
                    return String(component[..<index])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                default: break
                }
            }
            return nil
        }
    }
}
