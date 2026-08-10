import Foundation

struct ConstExprResolvedType: @unchecked Sendable {
    let type: Any.Type?
    let descriptor: ConstExprStaticTypeDescriptor
}

struct ConstExprTypeResolutionMetrics: Sendable, Equatable {
    var lookups = 0
    var cacheHits = 0
    var cacheMisses = 0
    var ambiguousLookups = 0
}

/// Resolves canonical source spellings against a registry and the intrinsic
/// standard-library generic constructors. The cache belongs to one source
/// evaluation, so source shadowing is checked by the evaluator before entry.
final class ConstExprTypeResolver {
    private enum Cached {
        case resolved(ConstExprResolvedType)
        case unavailable
    }

    private let index: ConstExprRegistryIndex
    private var cache: [ConstExprSourceTypeKey: Cached] = [:]
    private var reflectedKeys: [ObjectIdentifier: Set<ConstExprSourceTypeKey>] = [:]
    private(set) var metrics = ConstExprTypeResolutionMetrics()

    init(index: ConstExprRegistryIndex) {
        self.index = index
    }

    func resolve(sourceName: String) -> ConstExprResolvedType? {
        metrics.lookups += 1
        guard let key = ConstExprSourceTypeKey(sourceName: sourceName) else {
            metrics.cacheMisses += 1
            return nil
        }
        if let cached = cache[key] {
            metrics.cacheHits += 1
            switch cached {
            case .resolved(let result): return result
            case .unavailable: return nil
            }
        }
        metrics.cacheMisses += 1
        let result = resolve(key)
        cache[key] = result.map(Cached.resolved) ?? .unavailable
        return result
    }

    func type(_ type: Any.Type, matches sourceName: String) -> Bool {
        metrics.lookups += 1
        guard let sourceKey = ConstExprSourceTypeKey(sourceName: sourceName) else {
            metrics.cacheMisses += 1
            return false
        }
        let identifier = ObjectIdentifier(type)
        var keys = index.sourceKeys(for: type)
        if let cached = reflectedKeys[identifier] {
            metrics.cacheHits += 1
            keys.formUnion(cached)
        } else {
            metrics.cacheMisses += 1
            let reflected = ConstExprSourceTypeKey(sourceName: String(reflecting: type))
                .map(\ConstExprSourceTypeKey.lookupAliases) ?? []
            reflectedKeys[identifier] = reflected
            keys.formUnion(reflected)
        }
        return keys.contains(sourceKey)
    }

    private func resolve(_ key: ConstExprSourceTypeKey) -> ConstExprResolvedType? {
        let candidates = index.typeCandidates(for: key)
        if !candidates.isEmpty {
            var unique: [ConstExprIndexedType] = []
            for candidate in candidates {
                if let existing = unique.firstIndex(where: {
                    ObjectIdentifier($0.type) == ObjectIdentifier(candidate.type)
                }) {
                    unique[existing].descriptor = .fillingMissingMetadata(
                        from: candidate.descriptor,
                        into: unique[existing].descriptor
                    )
                } else {
                    unique.append(candidate)
                }
            }
            guard unique.count == 1 else {
                metrics.ambiguousLookups += 1
                return nil
            }
            return ConstExprResolvedType(
                type: unique[0].type,
                descriptor: unique[0].descriptor
            )
        }

        switch key {
        case .leaf(let name):
            guard let type = Self.builtinType(named: name) else { return nil }
            return ConstExprResolvedType(
                type: type,
                descriptor: .inferred(type, sourceName: key.sourceName)
            )
        case .optional(let wrappedKey):
            guard let wrapped = resolveCached(wrappedKey) else { return nil }
            return ConstExprResolvedType(
                type: wrapped.type.map(Self.optionalMetatype(wrapping:)),
                descriptor: .optional(wrapped.descriptor)
            )
        case .array(let elementKey):
            guard let element = resolveCached(elementKey) else { return nil }
            return ConstExprResolvedType(
                type: element.type.map(Self.arrayMetatype(of:)),
                descriptor: .array(element.descriptor)
            )
        case .dictionary(let keyKey, let valueKey):
            guard let keyType = resolveCached(keyKey),
                  let valueType = resolveCached(valueKey)
            else { return nil }
            let type = keyType.type.flatMap { key in
                valueType.type.flatMap { Self.dictionaryMetatype(key: key, value: $0) }
            }
            return ConstExprResolvedType(
                type: type,
                descriptor: .dictionary(key: keyType.descriptor, value: valueType.descriptor)
            )
        case .set(let elementKey):
            guard let element = resolveCached(elementKey) else { return nil }
            return ConstExprResolvedType(
                type: element.type.flatMap(Self.setMetatype(of:)),
                descriptor: .set(element.descriptor)
            )
        case .tuple(let elements):
            var descriptors: [ConstExprStaticTypeDescriptor] = []
            for element in elements {
                guard let resolved = resolveCached(element.type) else { return nil }
                descriptors.append(resolved.descriptor)
            }
            return ConstExprResolvedType(type: nil, descriptor: .tuple(descriptors))
        }
    }

    private func resolveCached(_ key: ConstExprSourceTypeKey) -> ConstExprResolvedType? {
        if let cached = cache[key] {
            metrics.cacheHits += 1
            switch cached {
            case .resolved(let result): return result
            case .unavailable: return nil
            }
        }
        metrics.cacheMisses += 1
        let result = resolve(key)
        cache[key] = result.map(Cached.resolved) ?? .unavailable
        return result
    }

    private static func builtinType(named name: String) -> Any.Type? {
        switch name {
        case "Any": return Any.self
        case "AnyHashable": return AnyHashable.self
        case "AnyObject": return AnyObject.self
        case "Bool": return Bool.self
        case "Character": return Character.self
        case "Double": return Double.self
        case "Float": return Float.self
        case "Int": return Int.self
        case "Int8": return Int8.self
        case "Int16": return Int16.self
        case "Int32": return Int32.self
        case "Int64": return Int64.self
        case "String": return String.self
        case "UInt": return UInt.self
        case "UInt8": return UInt8.self
        case "UInt16": return UInt16.self
        case "UInt32": return UInt32.self
        case "UInt64": return UInt64.self
        default: return nil
        }
    }

    private static func optionalMetatype(wrapping type: Any.Type) -> Any.Type {
        func open<Wrapped>(_ type: Wrapped.Type) -> Any.Type { Optional<Wrapped>.self }
        return _openExistential(type, do: open)
    }

    private static func arrayMetatype(of type: Any.Type) -> Any.Type {
        func open<Element>(_ type: Element.Type) -> Any.Type { Array<Element>.self }
        return _openExistential(type, do: open)
    }

    private static func setMetatype(of type: Any.Type) -> Any.Type? {
        guard let hashable = type as? any Hashable.Type else { return nil }
        func open<Element: Hashable>(_ type: Element.Type) -> Any.Type { Set<Element>.self }
        return _openExistential(hashable, do: open)
    }

    private static func dictionaryMetatype(key: Any.Type, value: Any.Type) -> Any.Type? {
        guard let hashable = key as? any Hashable.Type else { return nil }
        func openKey<Key: Hashable>(_ key: Key.Type) -> Any.Type {
            func openValue<Value>(_ value: Value.Type) -> Any.Type { Dictionary<Key, Value>.self }
            return _openExistential(value, do: openValue)
        }
        return _openExistential(hashable, do: openKey)
    }
}
