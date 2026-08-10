import SwiftSyntax

extension ConstExprValue {
    /// Retains a linked declaration's source-static result type after its
    /// implementation has produced a potentially more specific runtime value.
    /// Invalid manual registrations fail here instead of teaching overload
    /// resolution a narrowing conversion that Swift source would not perform.
    func withStaticType(
        _ declaredType: Any.Type,
        descriptor: ConstExprStaticTypeDescriptor
    ) throws -> Self {
        let descriptor = ConstExprStaticTypeDescriptor.fillingMissingMetadata(
            from: staticTypeDescriptor,
            into: descriptor
        )
        let exactTopLevelType = ObjectIdentifier(staticType) == ObjectIdentifier(declaredType)
        guard exactTopLevelType || ConstExprStaticTypeDescriptor.conversionRank(
            from: staticTypeDescriptor,
            sourceType: staticType,
            to: descriptor,
            targetType: declaredType
        ) != nil else {
            throw ConstExprValueError.typeMismatch(
                expected: descriptor.sourceName ?? String(reflecting: declaredType),
                actual: typeName
            )
        }
        return applying(
            descriptor: descriptor,
            topLevelType: declaredType
        )
    }

    func staticallyConverted(
        to declaredType: Any.Type?,
        descriptor: ConstExprStaticTypeDescriptor,
        sourceTypeName: String
    ) throws -> Self {
        guard ConstExprStaticTypeDescriptor.conversionRank(
            from: staticTypeDescriptor,
            sourceType: staticType,
            to: descriptor,
            targetType: declaredType
        ) != nil else {
            throw ConstExprValueError.typeMismatch(
                expected: sourceTypeName,
                actual: typeName
            )
        }
        return applying(
            descriptor: descriptor,
            topLevelType: declaredType,
            topLevelSourceName: sourceTypeName
        )
    }

    func applying(
        descriptor: ConstExprStaticTypeDescriptor,
        topLevelType: Any.Type? = nil,
        topLevelSourceName: String? = nil
    ) -> Self {
        let resultingType = topLevelType
            ?? Self.structuralMetatype(for: descriptor, convertingFrom: staticType)
            ?? staticType
        let isStructuralPayload: Bool
        switch payload {
        case .optional, .array, .dictionary, .tuple:
            isStructuralPayload = true
        case .opaque:
            isStructuralPayload = false
        }
        if case .leaf(_, _, _, let isClassBound, _) = descriptor,
           isStructuralPayload
        {
            let materialized = materializedRuntimeValue()
            return Self(
                payload: .opaque(ConstExprStructurallyErasedValue(value: self)),
                staticType: resultingType,
                explicitTypeName: topLevelSourceName ?? descriptor.sourceName,
                literalKind: literalKind,
                rawValue: materialized.value,
                hasRawValue: materialized.isAvailable,
                isStaticallyAnyObject: isClassBound,
                staticTypeDescriptor: descriptor,
                hasAuthoritativeStaticTypeDescriptor: true
            )
        }

        let rewrittenPayload: Payload
        var rewroteStructuralType = false
        switch (payload, descriptor) {
        case let (.optional(wrapped), .optional(wrappedDescriptor)):
            rewroteStructuralType = true
            rewrittenPayload = .optional(
                wrapped.map { $0.applying(descriptor: wrappedDescriptor) }
            )
        case let (_, .optional(wrappedDescriptor)):
            // `T` to `T?` is an optional-injection conversion, not a change
            // to the static metadata of the same runtime payload. Keeping an
            // opaque `T` while claiming `T?` makes later erasure to `Any`
            // unwrap the value when it is re-rendered. Preserve the injected
            // `.some` structurally so nested optionals and container
            // covariance retain every level of boxing.
            rewroteStructuralType = true
            rewrittenPayload = .optional(
                self.applying(descriptor: wrappedDescriptor)
            )
        case let (.array(elements), .array(elementDescriptor)):
            rewroteStructuralType = true
            rewrittenPayload = .array(
                elements.map { $0.applying(descriptor: elementDescriptor) }
            )
        case let (.dictionary(entries), .dictionary(keyDescriptor, valueDescriptor)):
            rewroteStructuralType = true
            rewrittenPayload = .dictionary(entries.map {
                (
                    $0.0.applying(descriptor: keyDescriptor),
                    $0.1.applying(descriptor: valueDescriptor)
                )
            })
        case let (.tuple(elements), .tuple(elementDescriptors))
            where elements.count == elementDescriptors.count:
            rewroteStructuralType = true
            rewrittenPayload = .tuple(zip(elements, elementDescriptors).map {
                (label: $0.0.label, value: $0.0.value.applying(descriptor: $0.1))
            })
        default:
            rewrittenPayload = payload
        }

        let retainsExistingTopLevelSpelling = topLevelType.map {
            ObjectIdentifier($0) == ObjectIdentifier(staticType)
        } ?? false
        let classBound: Bool
        if case .leaf(_, _, _, let isClassBound, _) = descriptor {
            classBound = isClassBound
        } else {
            classBound = false
        }
        let exactTopLevelType = ObjectIdentifier(resultingType) == ObjectIdentifier(staticType)
        return Self(
            payload: rewrittenPayload,
            staticType: resultingType,
            explicitTypeName: topLevelSourceName ?? (
                retainsExistingTopLevelSpelling
                    ? (explicitTypeName ?? descriptor.sourceName)
                    : (descriptor.sourceName ?? explicitTypeName)
            ),
            literalKind: literalKind,
            // A raw source container or scalar does not have the target
            // runtime type after optional injection or structural covariance.
            // Its rewritten payload can be decoded recursively instead.
            rawValue: rewroteStructuralType && !exactTopLevelType ? nil : rawValue,
            hasRawValue: rewroteStructuralType && !exactTopLevelType ? false : hasRawValue,
            isStaticallyAnyObject: classBound,
            staticTypeDescriptor: descriptor,
            hasAuthoritativeStaticTypeDescriptor: true
        )
    }

    /// Reconstructs generic container metatypes while recursively applying a
    /// descriptor. Top-level conversions already carry their declared
    /// metatype, but child conversions do not. Without this, the inner value
    /// of `T -> T??`, for example, could have an optional payload while still
    /// claiming `T.self` to overload resolution.
    static func structuralMetatype(
        for descriptor: ConstExprStaticTypeDescriptor,
        convertingFrom sourceType: Any.Type
    ) -> Any.Type? {
        switch descriptor {
        case .leaf(let type, _, _, _, _):
            return type

        case .optional(let wrapped):
            let sourceWrapped = wrappedType(ofOptionalType: sourceType) ?? sourceType
            guard let wrappedType = structuralMetatype(
                for: wrapped,
                convertingFrom: sourceWrapped
            ) else { return nil }
            func open<Wrapped>(_ type: Wrapped.Type) -> Any.Type {
                Optional<Wrapped>.self
            }
            return _openExistential(wrappedType, do: open)

        case .array(let element):
            let sourceElement = elementType(ofArrayType: sourceType) ?? Any.self
            guard let elementType = structuralMetatype(
                for: element,
                convertingFrom: sourceElement
            ) else { return nil }
            func open<Element>(_ type: Element.Type) -> Any.Type {
                Array<Element>.self
            }
            return _openExistential(elementType, do: open)

        case .set(let element):
            let sourceElement = elementType(ofSetType: sourceType) ?? AnyHashable.self
            guard let elementType = structuralMetatype(
                for: element,
                convertingFrom: sourceElement
            ), let hashableElement = elementType as? any Hashable.Type else { return nil }
            func open<Element: Hashable>(_ type: Element.Type) -> Any.Type {
                Set<Element>.self
            }
            return _openExistential(hashableElement, do: open)

        case .dictionary(let key, let value):
            let sourceComponents = keyAndValueTypes(ofDictionaryType: sourceType)
            guard let keyType = structuralMetatype(
                for: key,
                convertingFrom: sourceComponents?.key ?? AnyHashable.self
            ),
                let valueType = structuralMetatype(
                    for: value,
                    convertingFrom: sourceComponents?.value ?? Any.self
                ),
                let hashableKey = keyType as? any Hashable.Type
            else { return nil }

            func openKey<Key: Hashable>(_ type: Key.Type) -> Any.Type {
                func openValue<Value>(_ type: Value.Type) -> Any.Type {
                    Dictionary<Key, Value>.self
                }
                return _openExistential(valueType, do: openValue)
            }
            return _openExistential(hashableKey, do: openKey)

        case .tuple:
            // Swift does not expose a general erased tuple-metatype builder.
            // The declared top-level metatype remains authoritative; nested
            // tuple conversions that cannot prove one stay unmaterialized.
            return descriptor.matches(type: sourceType) ? sourceType : nil
        }
    }

    /// Materializes a parser-built structural payload as its recorded runtime
    /// type when every component can be decoded. The availability bit is
    /// separate because `Optional.none as Any` is a real boxed value even
    /// though ordinary optional-return APIs would represent it as `nil`.
    func materializedRuntimeValue() -> (value: Any?, isAvailable: Bool) {
        if hasRawValue {
            return (rawValue, true)
        }

        func open<T>(_ type: T.Type) -> (value: Any?, isAvailable: Bool) {
            do {
                let value = try require(type)
                return (value as Any, true)
            } catch {
                return (nil, false)
            }
        }
        return _openExistential(staticType, do: open)
    }

    func erasingLiteralProvenance() -> Self {
        let rewrittenPayload: Payload
        switch payload {
        case .opaque:
            rewrittenPayload = payload
        case .optional(let wrapped):
            rewrittenPayload = .optional(wrapped.map { $0.erasingLiteralProvenance() })
        case .array(let elements):
            rewrittenPayload = .array(elements.map { $0.erasingLiteralProvenance() })
        case .dictionary(let entries):
            rewrittenPayload = .dictionary(entries.map {
                ($0.0.erasingLiteralProvenance(), $0.1.erasingLiteralProvenance())
            })
        case .tuple(let elements):
            rewrittenPayload = .tuple(elements.map {
                ($0.label, $0.value.erasingLiteralProvenance())
            })
        }
        return Self(
            payload: rewrittenPayload,
            staticType: staticType,
            explicitTypeName: explicitTypeName,
            literalKind: nil,
            rawValue: rawValue,
            hasRawValue: hasRawValue,
            isStaticallyAnyObject: isStaticallyAnyObject,
            staticTypeDescriptor: staticTypeDescriptor,
            hasAuthoritativeStaticTypeDescriptor: hasAuthoritativeStaticTypeDescriptor
        )
    }

    static func classified(
        _ value: Any,
        staticType: Any.Type,
        literalKind: ConstExprLiteralKind?
    ) -> Self {
        let mirror = Mirror(reflecting: value)
        let reflectedType = String(reflecting: staticType)
        let hasExactRuntimeType = ObjectIdentifier(Swift.type(of: value))
            == ObjectIdentifier(staticType)

        if hasExactRuntimeType,
           mirror.displayStyle == .optional,
           let metadata = staticType as? any ConstExprOptionalTypeMetadata.Type
        {
            let wrapped = mirror.children.first.flatMap { child in
                metadata.constExprWrappedValue(from: child.value)
            }
            return Self(
                payload: .optional(wrapped),
                staticType: staticType,
                explicitTypeName: reflectedType,
                literalKind: literalKind,
                rawValue: value,
                hasRawValue: true
            )
        }

        if hasExactRuntimeType,
           mirror.displayStyle == .collection,
           reflectedType.hasPrefix("Swift.Array<"),
           let metadata = staticType as? any ConstExprArrayTypeMetadata.Type,
           let elements = metadata.constExprElements(from: value)
        {
            return Self(
                payload: .array(elements),
                staticType: staticType,
                explicitTypeName: reflectedType,
                literalKind: literalKind,
                rawValue: value,
                hasRawValue: true
            )
        }

        if hasExactRuntimeType,
           mirror.displayStyle == .dictionary,
           let metadata = staticType as? any ConstExprDictionaryTypeMetadata.Type,
           let entries = metadata.constExprEntries(from: value)
        {
            return Self(
                payload: .dictionary(entries),
                staticType: staticType,
                explicitTypeName: reflectedType,
                literalKind: literalKind,
                rawValue: value,
                hasRawValue: true
            )
        }

        if hasExactRuntimeType,
           mirror.displayStyle == .tuple,
           reflectedType.hasPrefix("(")
        {
            let elements = mirror.children.map { child in
                (
                    label: child.label.flatMap { $0.hasPrefix(".") ? nil : $0 },
                    value: classified(
                        child.value,
                        staticType: Swift.type(of: child.value),
                        literalKind: nil
                    )
                )
            }
            return Self(
                payload: .tuple(elements),
                staticType: staticType,
                explicitTypeName: reflectedType,
                literalKind: literalKind,
                rawValue: value,
                hasRawValue: true
            )
        }

        return Self(
            payload: .opaque(value),
            staticType: staticType,
            explicitTypeName: nil,
            literalKind: literalKind,
            rawValue: value,
            hasRawValue: true
        )
    }

}
