import Foundation

struct ConstExprIndexedType: @unchecked Sendable {
    let type: Any.Type
    var descriptor: ConstExprStaticTypeDescriptor
}

/// Immutable indexes compiled once when a registry value is constructed.
/// Evaluators share this storage through the value-semantic registry wrapper.
final class ConstExprRegistryIndex: @unchecked Sendable {
    struct NameAndKind: Hashable {
        let name: String
        let kind: ConstExprRegistrationKind
    }

    let registrationsByName: [String: [ConstExprRegistration]]
    let usableRegistrations: [ConstExprRegistration]
    let usableRegistrationsByName: [String: [ConstExprRegistration]]
    let usableRegistrationsByNameAndKind: [NameAndKind: [ConstExprRegistration]]
    let usableRegistrationsByOwnerType: [ObjectIdentifier: [ConstExprRegistration]]
    let usableArrayLiteralRegistrationsByOwnerType: [ObjectIdentifier: [ConstExprRegistration]]
    let typesBySourceKey: [ConstExprSourceTypeKey: [ConstExprIndexedType]]
    let sourceKeysByType: [ObjectIdentifier: Set<ConstExprSourceTypeKey>]
    let validationDiagnostics: [ConstExprDiagnostic]

    init(registrations: [ConstExprRegistration]) {
        registrationsByName = Dictionary(grouping: registrations, by: \ConstExprRegistration.name)
        let metadataDiagnostics = registrations.flatMap(\ConstExprRegistration.validationDiagnostics)
        let collidingIDs = Set(
            Dictionary(grouping: registrations, by: \ConstExprRegistration.declarationID)
                .filter { $0.value.count > 1 }
                .keys
        )
        validationDiagnostics = metadataDiagnostics + collidingIDs.sorted().map {
            ConstExprDiagnostic(
                severity: .error,
                code: "registry-collision",
                message: "duplicate const-expression registration '\($0)'"
            )
        }
        let usable = registrations.filter {
            $0.isValid && !collidingIDs.contains($0.declarationID)
        }
        usableRegistrations = usable
        usableRegistrationsByName = Dictionary(grouping: usable, by: \ConstExprRegistration.name)
        usableRegistrationsByNameAndKind = Dictionary(grouping: usable) {
            NameAndKind(name: $0.name, kind: $0.kind)
        }
        usableRegistrationsByOwnerType = Dictionary(
            grouping: usable.filter { $0.ownerType != nil }
        ) { ObjectIdentifier($0.ownerType!) }
        usableArrayLiteralRegistrationsByOwnerType = Dictionary(
            grouping: usable.filter { $0.kind == .arrayLiteral && $0.ownerType != nil }
        ) { ObjectIdentifier($0.ownerType!) }

        var types: [ConstExprSourceTypeKey: [ConstExprIndexedType]] = [:]
        var keysByType: [ObjectIdentifier: Set<ConstExprSourceTypeKey>] = [:]

        func merge(
            _ candidate: ConstExprIndexedType,
            under key: ConstExprSourceTypeKey
        ) {
            for alias in key.lookupAliases {
                keysByType[ObjectIdentifier(candidate.type), default: []].insert(alias)
                if let index = types[alias]?.firstIndex(where: {
                    ObjectIdentifier($0.type) == ObjectIdentifier(candidate.type)
                }) {
                    types[alias]![index].descriptor = .fillingMissingMetadata(
                        from: candidate.descriptor,
                        into: types[alias]![index].descriptor
                    )
                } else {
                    types[alias, default: []].append(candidate)
                }
            }
        }

        func index(
            _ type: Any.Type,
            descriptor: ConstExprStaticTypeDescriptor,
            explicitSourceName: String? = nil
        ) {
            let reflectedKey = ConstExprSourceTypeKey(
                sourceName: String(reflecting: type)
            )
            let explicitKey = explicitSourceName.flatMap(ConstExprSourceTypeKey.init(sourceName:))
            let descriptorKey = descriptor.sourceName.flatMap(ConstExprSourceTypeKey.init(sourceName:))
            let keys = Set([reflectedKey, explicitKey, descriptorKey].compactMap { $0 })
            let candidate = ConstExprIndexedType(type: type, descriptor: descriptor)
            for key in keys { merge(candidate, under: key) }

            switch descriptor {
            case .leaf:
                break
            case .optional(let wrapped):
                guard let wrappedType = ConstExprValue.wrappedType(ofOptionalType: type) else {
                    return
                }
                index(wrappedType, descriptor: wrapped)
            case .array(let element):
                guard let elementType = ConstExprValue.elementType(ofArrayType: type) else {
                    return
                }
                index(elementType, descriptor: element)
            case .dictionary(let key, let value):
                guard let components = ConstExprValue.keyAndValueTypes(ofDictionaryType: type) else {
                    return
                }
                index(components.key, descriptor: key)
                index(components.value, descriptor: value)
            case .set(let element):
                guard let elementType = ConstExprValue.elementType(ofSetType: type) else {
                    return
                }
                index(elementType, descriptor: element)
            case .tuple:
                // Swift has no general erased tuple-element metatype opener.
                // The complete reflected tuple key is still indexed above.
                break
            }
        }

        for registration in usable {
            for (type, descriptor) in zip(
                registration.parameterTypes,
                registration.parameterTypeDescriptors
            ) {
                index(type, descriptor: descriptor)
            }
            index(registration.resultType, descriptor: registration.resultTypeDescriptor)
            if let ownerType = registration.ownerType {
                index(
                    ownerType,
                    descriptor: .inferred(ownerType, sourceName: registration.ownerName),
                    explicitSourceName: registration.ownerName
                )
            }
            if let elementType = registration.arrayLiteralElementType,
               let descriptor = registration.arrayLiteralElementTypeDescriptor
            {
                index(elementType, descriptor: descriptor)
            }
        }

        typesBySourceKey = types
        sourceKeysByType = keysByType
    }

    func candidates(
        named name: String,
        kind: ConstExprRegistrationKind? = nil,
        ownerType: Any.Type? = nil,
        ownerName: String? = nil
    ) -> [ConstExprRegistration] {
        guard var candidates = registrationsByName[name] else { return [] }
        if let kind {
            candidates.removeAll { $0.kind != kind }
        }
        if let ownerType {
            let ownerID = ObjectIdentifier(ownerType)
            candidates.removeAll {
                guard let candidate = $0.ownerType else { return true }
                return ObjectIdentifier(candidate) != ownerID
            }
        }
        if let ownerName {
            candidates.removeAll {
                guard let candidate = $0.ownerName else { return true }
                return !Self.ownerName(candidate, matches: ownerName)
            }
        }
        return candidates
    }

    func usableCandidates(
        named name: String,
        kind: ConstExprRegistrationKind? = nil
    ) -> [ConstExprRegistration] {
        if let kind {
            return usableRegistrationsByNameAndKind[NameAndKind(name: name, kind: kind)] ?? []
        }
        return usableRegistrationsByName[name] ?? []
    }

    func usableCandidates(ownerType: Any.Type) -> [ConstExprRegistration] {
        usableRegistrationsByOwnerType[ObjectIdentifier(ownerType)] ?? []
    }

    func usableArrayLiteralCandidates(ownerType: Any.Type) -> [ConstExprRegistration] {
        usableArrayLiteralRegistrationsByOwnerType[ObjectIdentifier(ownerType)] ?? []
    }

    func typeCandidates(for key: ConstExprSourceTypeKey) -> [ConstExprIndexedType] {
        typesBySourceKey[key] ?? []
    }

    func sourceKeys(for type: Any.Type) -> Set<ConstExprSourceTypeKey> {
        sourceKeysByType[ObjectIdentifier(type)] ?? []
    }

    private static func ownerName(_ candidate: String, matches requested: String) -> Bool {
        if requested.contains(".") {
            return candidate == requested || candidate.hasSuffix("." + requested)
        }
        return candidate == requested
            || candidate.split(separator: ".").last.map(String.init) == requested
    }
}
