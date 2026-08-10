import Foundation
import SwiftParser
import SwiftParserDiagnostics
import SwiftSyntax

extension ConstExprSourceEvaluator {
    func registrations(
        named name: String,
        kind: ConstExprRegistrationKind,
        receiverType: Any.Type? = nil,
        ownerName: String? = nil
    ) -> [ConstExprRegistration] {
        let matches = indexedCandidates(named: name, kind: kind).filter { registration in
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

    func canInvokeRegistration(_ registration: ConstExprRegistration) -> Bool {
        registration.availabilityState(in: availabilityContext) == .available
            && (!registration.isThrowing
            || (throwingContextDepth > 0
                && (locallyHandledThrowingContextDepth > 0
                    || suppressThrowingRegistrations == 0)))
            && !isShadowedBySourceExtension(registration)
    }

    func noteThrowingInvocation(_ registration: ConstExprRegistration) {
        guard registration.isThrowing, !throwingInvocationFrames.isEmpty else { return }
        let index = throwingInvocationFrames.index(
            before: throwingInvocationFrames.endIndex
        )
        throwingInvocationFrames[index] = true
    }

    func isShadowedBySourceExtension(
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

    func moduleRegistrations(
        named name: String,
        moduleName: String,
        kinds: Set<ConstExprRegistrationKind>
    ) -> [ConstExprRegistration] {
        indexedCandidates(named: name).filter {
            canInvokeRegistration($0)
                && $0.name == name
                && kinds.contains($0.kind)
                && $0.moduleName == moduleName
        }
    }

    func indexedCandidates(
        named name: String,
        kind: ConstExprRegistrationKind? = nil
    ) -> [ConstExprRegistration] {
        let candidates = registryIndex.usableCandidates(named: name, kind: kind)
        candidateRegistrationCount += candidates.count
        return candidatesWithKnownAvailability(candidates)
    }

    func indexedCandidates(ownerType: Any.Type) -> [ConstExprRegistration] {
        let candidates = registryIndex.usableCandidates(ownerType: ownerType)
        candidateRegistrationCount += candidates.count
        return candidatesWithKnownAvailability(candidates)
    }

    func indexedArrayLiteralCandidates(
        ownerType: Any.Type
    ) -> [ConstExprRegistration] {
        let candidates = registryIndex.usableArrayLiteralCandidates(ownerType: ownerType)
        candidateRegistrationCount += candidates.count
        return candidatesWithKnownAvailability(candidates)
    }

    func candidatesWithKnownAvailability(
        _ candidates: [ConstExprRegistration]
    ) -> [ConstExprRegistration] {
        if candidates.contains(where: {
            $0.availabilityState(in: availabilityContext) == .unknown
        }) {
            encounteredUnknownAvailability = true
            return []
        }
        return candidates
    }

    func argumentMapping(
        for registration: ConstExprRegistration,
        labels: [String?]
    ) -> [Int?]? {
        let key = ArgumentMappingKey(
            declarationID: registration.declarationID,
            labels: labels
        )
        if let cached = argumentMappings[key] {
            switch cached {
            case .valid(let mapping): return mapping
            case .invalid: return nil
            }
        }
        let mapping = registration.argumentMapping(labels: labels)
        argumentMappings[key] = mapping.map(CachedArgumentMapping.valid) ?? .invalid
        return mapping
    }

    struct CallMatch {
        var arguments: [ConstExprValue?]
        var conversionRanks: [Int]
        var argumentTypes: [Any.Type]
        var argumentDescriptors: [ConstExprStaticTypeDescriptor]
        var sourceTypes: [Any.Type]
        var sourceDescriptors: [ConstExprStaticTypeDescriptor]
        var omittedDefaults: Int
    }

    struct ViableCall {
        var registration: ConstExprRegistration
        var arguments: [ConstExprValue?]
        var conversionRanks: [Int]
        var argumentTypes: [Any.Type]
        var argumentDescriptors: [ConstExprStaticTypeDescriptor]
        var sourceTypes: [Any.Type]
        var sourceDescriptors: [ConstExprStaticTypeDescriptor]
        var omittedDefaults: Int
    }

    func match(
        _ registration: ConstExprRegistration,
        labels: [String?],
        values: [ConstExprValue]
    ) -> CallMatch? {
        guard labels.count == values.count else { return nil }
        guard let mapping = argumentMapping(for: registration, labels: labels) else { return nil }
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

    func agreedArgumentType(
        registrations: [ConstExprRegistration],
        labels: [String?],
        argumentIndex: Int
    ) -> Any.Type? {
        let types = registrations.compactMap { registration -> Any.Type? in
            guard let mapping = argumentMapping(for: registration, labels: labels),
                let parameterIndex = mapping.firstIndex(where: { $0 == argumentIndex })
            else { return nil }
            return registration.parameterTypes[parameterIndex]
        }
        guard let first = types.first,
            types.allSatisfy({ sameType($0, first) })
        else { return nil }
        return first
    }

    func requiresRuntimeValueWitness(for type: Any.Type) -> Bool {
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

    func nonDominated(_ candidates: [ViableCall]) -> [ViableCall] {
        candidates.filter { candidate in
            !candidates.contains { other in
                other.registration.declarationID != candidate.registration.declarationID
                    && dominates(other, candidate)
            }
        }
    }

    func dominates(_ lhs: ViableCall, _ rhs: ViableCall) -> Bool {
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
        if lhs.omittedDefaults != rhs.omittedDefaults {
            return lhs.omittedDefaults < rhs.omittedDefaults
        }
        if lhs.registration.isDisfavoredOverload != rhs.registration.isDisfavoredOverload {
            return !lhs.registration.isDisfavoredOverload
        }
        return false
    }

    /// Models only conversions that establish declaration specificity. A
    /// concrete class conforming to an unrelated protocol is intentionally not
    /// considered more specific than that protocol: Swift treats superclass
    /// and protocol overloads as incomparable for a subclass argument. The
    /// existential witness is used for argument viability, not to invent a
    /// total order between those parameter domains.
    func parameterDescriptorConverts(
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

    /// Filters a registered operator overload set by the source result
    /// context before its operands are evaluated. This mirrors Swift's
    /// bidirectional constraint solving closely enough to provide literal
    /// context only when every best-result candidate agrees on an operand
    /// type. Argument ranking still runs after evaluation and must select one
    /// unique overload before any registration is invoked.
    func registeredOperatorCandidates(
        named name: String,
        kind: ConstExprRegistrationKind,
        expectedTypeName: String?
    ) -> [ConstExprRegistration] {
        let candidates = indexedCandidates(named: name, kind: kind).filter {
            canInvokeRegistration($0) && $0.name == name && $0.kind == kind
        }
        guard let expectedTypeName else { return candidates }
        let ranked = candidates.compactMap {
            registration -> (registration: ConstExprRegistration, rank: Int)? in
            guard let rank = expectedResultConversionRank(
                registration.resultType,
                resultDescriptor: registration.resultTypeDescriptor,
                expectedSourceName: expectedTypeName
            ) else { return nil }
            return (registration, rank)
        }
        guard let bestRank = ranked.map(\.rank).min() else { return [] }
        return ranked.filter { $0.rank == bestRank }.map(\.registration)
    }

}
