import SwiftParser
import SwiftParserDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder

public enum ConstExprValueError: Error, Sendable, Equatable, CustomStringConvertible {
    case typeMismatch(expected: String, actual: String)
    case notRepresentable(String)
    case malformedCollection(String)

    public var description: String {
        switch self {
        case .typeMismatch(let expected, let actual):
            "expected \(expected), found \(actual)"
        case .notRepresentable(let type):
            "\(type) cannot be rendered as a Swift constant expression"
        case .malformedCollection(let message):
            message
        }
    }
}

/// Describes source-literal provenance used during overload resolution.
///
/// Swift permits an integer literal to initialize several numeric types and a
/// one-character string literal to initialize `Character`. Those conversions
/// must not be applied to an arbitrary computed `Int` or `String`, so ordinary
/// ``ConstExprValue/init(_:)`` values intentionally have no literal provenance.
public enum ConstExprLiteralKind: String, Sendable, Hashable {
    case integer
    case floatingPoint
    case string
    case boolean
    case nilLiteral
}

/// The structural category of a constant-expression value.
public enum ConstExprValueKind: String, Sendable, Hashable {
    case opaque
    case optional
    case array
    case dictionary
    case tuple
}

/// A type that can emit a Swift expression preserving the value's static type.
public protocol ConstExprRepresentable {
    func constExprExpression() throws -> ExprSyntax
}

/// A type that can be decoded from the evaluator's structural value model.
public protocol ConstExprValueDecodable {
    static func decodeConstExprValue(_ value: ConstExprValue) throws -> Self
}

private protocol ConstExprOptionalTypeMetadata {
    static var constExprWrappedType: Any.Type { get }
    static func constExprNilValue() -> ConstExprValue
    static func constExprWrappedValue(from value: Any) -> ConstExprValue?
}

private protocol ConstExprArrayTypeMetadata {
    static var constExprElementType: Any.Type { get }
    static func constExprElements(from value: Any) -> [ConstExprValue]?
}

private protocol ConstExprDictionaryTypeMetadata {
    static var constExprKeyType: Any.Type { get }
    static var constExprValueType: Any.Type { get }
    static func constExprEntries(
        from value: Any
    ) -> [(ConstExprValue, ConstExprValue)]?
}

/// Standard-library containers whose array-literal construction can be opened
/// safely for an erased exact metatype. This is intentionally private: user
/// conformances require an explicit registry adapter before their code runs.
private protocol ConstExprStandardArrayLiteralTypeMetadata {
    static var constExprArrayLiteralElementType: Any.Type { get }
    static func constExprArrayLiteralValue(
        from elements: [ConstExprValue],
        sourceTypeName: String
    ) throws -> ConstExprValue
}

/// Opens a standard-library container's generic arguments so structural
/// values can be decoded even when their custom element types do not conform
/// to `ConstExprValueDecodable`. Exact opaque elements already know how to
/// decode themselves through `require`, so imposing a conformance on every
/// annotated nominal would be unnecessary boilerplate.
private protocol ConstExprStructuralValueDecodable {
    static func decodeStructuralConstExprValue(_ value: ConstExprValue) throws -> Any
}

/// Retains a structural value's complete source-static expression while its
/// outer type is erased to a leaf such as `Any`. Rendering the wrapped value
/// first is essential for optionals and heterogeneous containers: erasing each
/// child independently would change the runtime value being boxed.
private struct ConstExprStructurallyErasedValue: ConstExprRepresentable {
    let value: ConstExprValue

    func constExprExpression() throws -> ExprSyntax {
        try value.constExprExpression()
    }
}

/// A type-erased value produced while evaluating source.
///
/// Custom registered values may remain opaque and still flow through registered
/// methods and properties. Only a terminal value needs to be representable.
public struct ConstExprValue {
    indirect enum Payload {
        case opaque(Any)
        case optional(ConstExprValue?)
        case array([ConstExprValue])
        case dictionary([(ConstExprValue, ConstExprValue)])
        case tuple([(label: String?, value: ConstExprValue)])
    }

    let payload: Payload
    public let staticType: Any.Type
    public let staticTypeDescriptor: ConstExprStaticTypeDescriptor
    let explicitTypeName: String?
    public let literalKind: ConstExprLiteralKind?
    public let isStaticallyAnyObject: Bool
    let hasAuthoritativeStaticTypeDescriptor: Bool

    // Structural values constructed by the parser do not necessarily have a
    // corresponding runtime Swift container. Values boxed from linked Swift
    // code retain one so exact casts, including labeled tuples, remain cheap.
    private let rawValue: Any?
    private let hasRawValue: Bool

    /// Wraps a computed value. This initializer deliberately does not mark the
    /// value as a source literal.
    public init<T>(_ value: T) {
        self = Self.classified(value as Any, staticType: T.self, literalKind: nil)
    }

    /// Wraps a value while retaining a declaration's erased static result
    /// type. Macro-generated adapters use this initializer for existential and
    /// `Any` results because Swift's implicitly-opened existentials would
    /// otherwise infer the concrete dynamic type for the generic initializer.
    public init(
        _ value: Any,
        preservingStaticType staticType: Any.Type,
        sourceTypeName: String? = nil,
        isStaticallyAnyObject: Bool? = nil
    ) {
        func isRuntimeCompatible<T>(with type: T.Type) -> Bool {
            value is T
        }
        guard _openExistential(staticType, do: isRuntimeCompatible) else {
            // A manual caller can spell metadata that no Swift declaration
            // could have produced. Retain the honest dynamic type so a
            // registration's declared-result validation rejects the value
            // instead of rendering a parsed but ill-typed cast.
            self = Self.classified(
                value,
                staticType: Swift.type(of: value),
                literalKind: nil
            )
            return
        }

        let classified = Self.classified(value, staticType: staticType, literalKind: nil)
        guard (sourceTypeName?.isEmpty == false) || isStaticallyAnyObject != nil else {
            self = classified
            return
        }
        let metatypeKind = String(reflecting: Swift.type(of: staticType))
        let isExistential = metatypeKind.hasSuffix(".Protocol")
        let verifiedClassBound: Bool?
        if staticType == Any.self {
            verifiedClassBound = false
        } else if staticType == AnyObject.self || staticType is AnyClass {
            verifiedClassBound = true
        } else if isExistential {
            // Runtime existential metatypes do not expose their class-bound
            // constraint. Macro-generated metadata is compiler-checked;
            // equivalent manual metadata remains part of the trust boundary.
            verifiedClassBound = isStaticallyAnyObject
        } else {
            verifiedClassBound = false
        }
        self = Self(
            payload: classified.payload,
            staticType: classified.staticType,
            explicitTypeName: sourceTypeName?.isEmpty == false ? sourceTypeName : nil,
            literalKind: classified.literalKind,
            rawValue: classified.rawValue,
            hasRawValue: classified.hasRawValue,
            isStaticallyAnyObject: verifiedClassBound
                ?? classified.isStaticallyAnyObject,
            staticTypeDescriptor: .inferred(
                staticType,
                sourceName: sourceTypeName,
                isClassBound: verifiedClassBound
            )
        )
    }

    /// Wraps a value whose concrete type may only be known dynamically.
    public static func opaque<T>(_ value: T) -> Self {
        Self(value)
    }

    /// Creates the default `Int` representation of an integer source literal.
    public static func integerLiteral(_ value: Int) -> Self {
        Self.classified(value, staticType: Int.self, literalKind: .integer)
    }

    /// Creates the default `Double` representation of a floating source literal.
    public static func floatingPointLiteral(_ value: Double) -> Self {
        Self.classified(value, staticType: Double.self, literalKind: .floatingPoint)
    }

    /// Creates the default `String` representation of a string source literal.
    public static func stringLiteral(_ value: String) -> Self {
        Self.classified(value, staticType: String.self, literalKind: .string)
    }

    public static func booleanLiteral(_ value: Bool) -> Self {
        Self.classified(value, staticType: Bool.self, literalKind: .boolean)
    }

    public static func nilLiteral() -> Self {
        return Self(
            payload: .optional(nil),
            staticType: Optional<Any>.self,
            explicitTypeName: nil,
            literalKind: .nilLiteral
        )
    }

    /// Creates a typed structural optional. Its wrapped value can be decoded
    /// recursively even when there is no boxed `Optional<T>` runtime value.
    public static func optional<T>(_ value: T?, wrappedBy type: T.Type = T.self) -> Self {
        let wrapped = value.map(Self.init)
        return Self(
            payload: .optional(wrapped),
            staticType: Optional<T>.self,
            explicitTypeName: String(reflecting: Optional<T>.self),
            literalKind: nil,
            rawValue: value as Any,
            hasRawValue: true,
            staticTypeDescriptor: .optional(
                wrapped?.staticTypeDescriptor ?? .inferred(T.self)
            )
        )
    }

    /// Lifts an already-erased value into an optional whose wrapped metatype is
    /// only known at runtime. This is used when optional chaining changes a
    /// registered member's `T` result into `T?`.
    public static func optional(
        _ wrapped: ConstExprValue?,
        wrappedType: Any.Type
    ) -> Self {
        func open<Wrapped>(_ type: Wrapped.Type) -> ConstExprValue {
            ConstExprValue(
                payload: .optional(wrapped),
                staticType: Optional<Wrapped>.self,
                explicitTypeName: String(reflecting: Optional<Wrapped>.self),
                literalKind: nil,
                staticTypeDescriptor: .optional(
                    wrapped?.staticTypeDescriptor ?? .inferred(wrappedType)
                )
            )
        }
        return _openExistential(wrappedType, do: open)
    }

    /// Creates a typed `nil` when `optionalType` is an `Optional<T>` metatype.
    ///
    /// The optional's wrapped type is recovered without requiring callers to
    /// know `T` statically. This is primarily useful when an erased callable
    /// result participates in `try?` or optional chaining, both of which must
    /// preserve Swift's optional-flattening rules.
    public static func nilValue(ofOptionalType optionalType: Any.Type) -> Self? {
        guard let metadata = optionalType as? any ConstExprOptionalTypeMetadata.Type else {
            return nil
        }
        return metadata.constExprNilValue()
    }

    static func wrappedType(ofOptionalType optionalType: Any.Type) -> Any.Type? {
        (optionalType as? any ConstExprOptionalTypeMetadata.Type)?.constExprWrappedType
    }

    static func elementType(ofArrayType arrayType: Any.Type) -> Any.Type? {
        (arrayType as? any ConstExprArrayTypeMetadata.Type)?.constExprElementType
    }

    static func standardArrayLiteralElementType(
        of resultType: Any.Type
    ) -> Any.Type? {
        (resultType as? any ConstExprStandardArrayLiteralTypeMetadata.Type)?
            .constExprArrayLiteralElementType
    }

    static func standardArrayLiteralValue(
        from elements: [ConstExprValue],
        as resultType: Any.Type,
        sourceTypeName: String
    ) throws -> Self? {
        guard let metadata = resultType
            as? any ConstExprStandardArrayLiteralTypeMetadata.Type
        else {
            return nil
        }
        return try metadata.constExprArrayLiteralValue(
            from: elements,
            sourceTypeName: sourceTypeName
        )
    }

    static func keyAndValueTypes(
        ofDictionaryType dictionaryType: Any.Type
    ) -> (key: Any.Type, value: Any.Type)? {
        guard let metadata = dictionaryType as? any ConstExprDictionaryTypeMetadata.Type else {
            return nil
        }
        return (metadata.constExprKeyType, metadata.constExprValueType)
    }

    /// Backwards-compatible spelling for an untyped nil literal.
    public static func untypedNil() -> Self {
        nilLiteral()
    }

    /// Creates a structural array. Pass a source-valid type spelling when an
    /// empty or non-default-typed array must retain explicit static context.
    public static func array(
        _ elements: [ConstExprValue],
        typeName: String? = nil
    ) -> Self {
        Self(
            payload: .array(elements),
            staticType: [ConstExprValue].self,
            explicitTypeName: typeName,
            literalKind: nil,
            staticTypeDescriptor: .array(
                elements.first?.staticTypeDescriptor ?? .inferred(Any.self)
            )
        )
    }

    /// Decodes elements and creates a boxed, statically typed Swift array.
    public static func array<Element: ConstExprValueDecodable>(
        _ elements: [ConstExprValue],
        as type: [Element].Type
    ) throws -> Self {
        Self(try elements.map(Element.decodeConstExprValue))
    }

    /// Creates a structural dictionary. Entry order does not affect rendering.
    public static func dictionary(
        _ entries: [(ConstExprValue, ConstExprValue)],
        typeName: String? = nil
    ) -> Self {
        Self(
            payload: .dictionary(entries),
            staticType: [(ConstExprValue, ConstExprValue)].self,
            explicitTypeName: typeName,
            literalKind: nil,
            staticTypeDescriptor: .dictionary(
                key: entries.first?.0.staticTypeDescriptor ?? .inferred(Any.self),
                value: entries.first?.1.staticTypeDescriptor ?? .inferred(Any.self)
            )
        )
    }

    /// Decodes entries and creates a boxed, statically typed Swift dictionary.
    public static func dictionary<Key, Value>(
        _ entries: [(ConstExprValue, ConstExprValue)],
        as type: [Key: Value].Type
    ) throws -> Self
    where Key: ConstExprValueDecodable & Hashable, Value: ConstExprValueDecodable {
        var result: [Key: Value] = [:]
        for (key, value) in entries {
            result[try Key.decodeConstExprValue(key)] = try Value.decodeConstExprValue(value)
        }
        return Self(result)
    }

    /// Creates a structural tuple. Tuple elements remain publicly inspectable
    /// so generated adapters can decode tuple parameters component-by-component.
    public static func tuple(
        _ elements: [(label: String?, value: ConstExprValue)],
        typeName: String? = nil
    ) -> Self {
        Self(
            payload: .tuple(elements),
            staticType: Any.self,
            explicitTypeName: typeName,
            literalKind: nil,
            staticTypeDescriptor: .tuple(elements.map { $0.value.staticTypeDescriptor })
        )
    }

    /// Creates a boxed two-element tuple from structural elements.
    public static func tuple<A, B>(
        _ elements: [(label: String?, value: ConstExprValue)],
        as type: (A, B).Type
    ) throws -> Self
    where A: ConstExprValueDecodable, B: ConstExprValueDecodable {
        guard elements.count == 2 else {
            throw ConstExprValueError.malformedCollection(
                "expected 2 tuple elements, found \(elements.count)"
            )
        }
        let raw = (
            try A.decodeConstExprValue(elements[0].value),
            try B.decodeConstExprValue(elements[1].value)
        )
        return Self(
            payload: .tuple(elements),
            staticType: type,
            explicitTypeName: String(reflecting: type),
            literalKind: nil,
            rawValue: raw,
            hasRawValue: true,
            staticTypeDescriptor: .tuple(elements.map { $0.value.staticTypeDescriptor })
        )
    }

    /// Creates a boxed three-element tuple from structural elements.
    public static func tuple<A, B, C>(
        _ elements: [(label: String?, value: ConstExprValue)],
        as type: (A, B, C).Type
    ) throws -> Self
    where A: ConstExprValueDecodable, B: ConstExprValueDecodable,
          C: ConstExprValueDecodable {
        guard elements.count == 3 else {
            throw ConstExprValueError.malformedCollection(
                "expected 3 tuple elements, found \(elements.count)"
            )
        }
        let raw = (
            try A.decodeConstExprValue(elements[0].value),
            try B.decodeConstExprValue(elements[1].value),
            try C.decodeConstExprValue(elements[2].value)
        )
        return Self(
            payload: .tuple(elements),
            staticType: type,
            explicitTypeName: String(reflecting: type),
            literalKind: nil,
            rawValue: raw,
            hasRawValue: true,
            staticTypeDescriptor: .tuple(elements.map { $0.value.staticTypeDescriptor })
        )
    }

    private init(
        payload: Payload,
        staticType: Any.Type,
        explicitTypeName: String?,
        literalKind: ConstExprLiteralKind?,
        rawValue: Any? = nil,
        hasRawValue: Bool = false,
        isStaticallyAnyObject: Bool? = nil,
        staticTypeDescriptor: ConstExprStaticTypeDescriptor? = nil,
        hasAuthoritativeStaticTypeDescriptor: Bool? = nil
    ) {
        self.payload = payload
        self.staticType = staticType
        self.explicitTypeName = explicitTypeName
        self.literalKind = literalKind
        self.rawValue = rawValue
        self.hasRawValue = hasRawValue
        self.isStaticallyAnyObject = isStaticallyAnyObject ?? (staticType is AnyClass)
        self.staticTypeDescriptor = staticTypeDescriptor ?? .inferred(
            staticType,
            sourceName: explicitTypeName,
            isClassBound: isStaticallyAnyObject
        )
        self.hasAuthoritativeStaticTypeDescriptor =
            hasAuthoritativeStaticTypeDescriptor ?? hasRawValue
    }

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

    private func applying(
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
    private static func structuralMetatype(
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
    private func materializedRuntimeValue() -> (value: Any?, isAvailable: Bool) {
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

    fileprivate static func classified(
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

    public var kind: ConstExprValueKind {
        switch payload {
        case .opaque: .opaque
        case .optional: .optional
        case .array: .array
        case .dictionary: .dictionary
        case .tuple: .tuple
        }
    }

    public var typeName: String {
        explicitTypeName ?? String(reflecting: staticType)
    }

    public var isOptional: Bool {
        if case .optional = payload { return true }
        return false
    }

    /// The wrapped metatype for a typed optional, including a typed nil.
    public var optionalWrappedType: Any.Type? {
        (staticType as? any ConstExprOptionalTypeMetadata.Type)?.constExprWrappedType
    }

    public func optionalWraps(_ type: Any.Type) -> Bool {
        guard let optionalWrappedType else { return false }
        return ObjectIdentifier(optionalWrappedType) == ObjectIdentifier(type)
    }

    public var isNil: Bool {
        if case .optional(nil) = payload { return true }
        return false
    }

    /// The payload of a non-nil optional, or `nil` for both a nil optional and
    /// a non-optional value. Use ``isOptional``/``isNil`` to distinguish them.
    public var wrappedValue: ConstExprValue? {
        guard case .optional(let value) = payload else { return nil }
        return value
    }

    public var arrayElements: [ConstExprValue]? {
        guard case .array(let values) = payload else { return nil }
        return values
    }

    public var dictionaryEntries: [(key: ConstExprValue, value: ConstExprValue)]? {
        guard case .dictionary(let entries) = payload else { return nil }
        return entries.map { (key: $0.0, value: $0.1) }
    }

    public var tupleElements: [(label: String?, value: ConstExprValue)]? {
        guard case .tuple(let elements) = payload else { return nil }
        return elements
    }

    var hasBoxedRuntimeValue: Bool { hasRawValue }

    var hasExistentialStaticType: Bool {
        String(reflecting: Swift.type(of: staticType)).hasSuffix(".Protocol")
    }

    func provesStaticValueConversion(to target: Any.Type) -> Bool {
        guard case .opaque(let value) = payload,
              hasRawValue,
              ObjectIdentifier(Swift.type(of: value)) == ObjectIdentifier(staticType)
        else { return false }

        func opensTarget<T>(_ target: T.Type) -> Bool {
            value is T
        }
        return _openExistential(target, do: opensTarget)
    }

    public var dynamicTypeIdentifier: ObjectIdentifier? {
        guard case .opaque(let value) = payload else {
            return hasRawValue ? ObjectIdentifier(staticType) : nil
        }
        return ObjectIdentifier(Swift.type(of: value))
    }

    public func isExactly<T>(_ type: T.Type) -> Bool {
        if staticType == type { return true }
        guard case .opaque(let value) = payload else { return false }
        return Swift.type(of: value) == type
    }

    /// Returns an exact value or a conversion permitted by source-literal
    /// provenance. Structural collections decode recursively.
    public func require<T>(_ type: T.Type = T.self) throws -> T {
        if let value: T = convertedScalar(to: type) {
            return value
        }

        if let decoder = T.self as? any ConstExprValueDecodable.Type {
            let decoded = try decoder.decodeConstExprValue(self)
            if let typed = decoded as? T {
                return typed
            }
        }

        if let decoder = T.self as? any ConstExprStructuralValueDecodable.Type {
            let decoded = try decoder.decodeStructuralConstExprValue(self)
            if let typed = decoded as? T {
                return typed
            }
        }

        throw ConstExprValueError.typeMismatch(
            expected: String(reflecting: T.self),
            actual: typeName
        )
    }

    /// Decodes an unlabeled two-element tuple. Tuple types cannot currently
    /// adopt library protocols without an experimental language feature, so
    /// tuple arities use focused overloads instead of `ConstExprValueDecodable`.
    public func require<A, B>(_ type: (A, B).Type) throws -> (A, B)
    where A: ConstExprValueDecodable, B: ConstExprValueDecodable {
        if let exact = raw(as: type) { return exact }
        guard case .tuple(let elements) = payload, elements.count == 2 else {
            throw tupleMismatch(expected: String(reflecting: type), count: 2)
        }
        return (
            try A.decodeConstExprValue(elements[0].value),
            try B.decodeConstExprValue(elements[1].value)
        )
    }

    public func require<A, B, C>(_ type: (A, B, C).Type) throws -> (A, B, C)
    where A: ConstExprValueDecodable, B: ConstExprValueDecodable,
          C: ConstExprValueDecodable {
        if let exact = raw(as: type) { return exact }
        guard case .tuple(let elements) = payload, elements.count == 3 else {
            throw tupleMismatch(expected: String(reflecting: type), count: 3)
        }
        return (
            try A.decodeConstExprValue(elements[0].value),
            try B.decodeConstExprValue(elements[1].value),
            try C.decodeConstExprValue(elements[2].value)
        )
    }

    public func require<A, B, C, D>(_ type: (A, B, C, D).Type) throws -> (A, B, C, D)
    where A: ConstExprValueDecodable, B: ConstExprValueDecodable,
          C: ConstExprValueDecodable, D: ConstExprValueDecodable {
        if let exact = raw(as: type) { return exact }
        guard case .tuple(let elements) = payload, elements.count == 4 else {
            throw tupleMismatch(expected: String(reflecting: type), count: 4)
        }
        return (
            try A.decodeConstExprValue(elements[0].value),
            try B.decodeConstExprValue(elements[1].value),
            try C.decodeConstExprValue(elements[2].value),
            try D.decodeConstExprValue(elements[3].value)
        )
    }

    private func tupleMismatch(expected: String, count: Int) -> ConstExprValueError {
        guard case .tuple(let elements) = payload else {
            return .typeMismatch(expected: expected, actual: typeName)
        }
        return .malformedCollection(
            "expected \(count) tuple elements for \(expected), found \(elements.count)"
        )
    }

    public func cast<T>(to type: T.Type = T.self) -> T? {
        try? require(type)
    }

    public func canDecode<T>(_ type: T.Type = T.self) -> Bool {
        cast(to: type) != nil
    }

    func canDecode(_ type: Any.Type) -> Bool {
        if staticType == type { return true }
        if type == Any.self { return true }
        if type == AnyObject.self, staticType is AnyClass { return true }
        if isStaticSubtype(of: type) { return true }
        if literalConverted(to: type) != nil { return true }
        if let decoder = type as? any ConstExprValueDecodable.Type {
            return (try? decoder.decodeConstExprValue(self)) != nil
        }
        if let decoder = type as? any ConstExprStructuralValueDecodable.Type {
            return (try? decoder.decodeStructuralConstExprValue(self)) != nil
        }
        return false
    }

    /// Returns whether every value of the recorded static source type can be
    /// passed to `type` through Swift's class upcast conversion. This uses the
    /// metatype rather than the boxed object's dynamic class, so a `Base`
    /// expression containing a `Derived` instance never gains an implicit
    /// downcast during overload resolution.
    func isStaticSubtype(of type: Any.Type) -> Bool {
        func opensTarget<T>(_ target: T.Type) -> Bool {
            staticType is T.Type
        }
        return _openExistential(type, do: opensTarget)
    }

    /// Converts a literal-origin value to a concrete built-in type. The result
    /// keeps literal provenance so callers may retain conversion-ranking data.
    public func literalConverted(to type: Any.Type) -> ConstExprValue? {
        switch literalKind {
        case .integer:
            guard let value = raw(as: Int.self) else { return nil }
            if type == Int.self { return self }
            if type == Int8.self, let converted = Int8(exactly: value) { return .literal(converted, .integer) }
            if type == Int16.self, let converted = Int16(exactly: value) { return .literal(converted, .integer) }
            if type == Int32.self, let converted = Int32(exactly: value) { return .literal(converted, .integer) }
            if type == Int64.self, let converted = Int64(exactly: value) { return .literal(converted, .integer) }
            if type == UInt.self, let converted = UInt(exactly: value) { return .literal(converted, .integer) }
            if type == UInt8.self, let converted = UInt8(exactly: value) { return .literal(converted, .integer) }
            if type == UInt16.self, let converted = UInt16(exactly: value) { return .literal(converted, .integer) }
            if type == UInt32.self, let converted = UInt32(exactly: value) { return .literal(converted, .integer) }
            if type == UInt64.self, let converted = UInt64(exactly: value) { return .literal(converted, .integer) }
            if type == Double.self { return .literal(Double(value), .integer) }
            if type == Float.self { return .literal(Float(value), .integer) }
            return nil

        case .floatingPoint:
            guard let value = raw(as: Double.self) else { return nil }
            if type == Double.self { return self }
            if type == Float.self { return .literal(Float(value), .floatingPoint) }
            return nil

        case .string:
            guard let value = raw(as: String.self) else { return nil }
            if type == String.self { return self }
            if type == Character.self, value.count == 1, let first = value.first {
                return .literal(first, .string)
            }
            return nil

        case .boolean:
            return type == Bool.self ? self : nil

        case .nilLiteral:
            return String(reflecting: type).hasPrefix("Swift.Optional<") ? self : nil

        case nil:
            return nil
        }
    }

    private static func literal<T>(_ value: T, _ kind: ConstExprLiteralKind) -> Self {
        classified(value as Any, staticType: T.self, literalKind: kind)
    }

    public func constExprExpression() throws -> ExprSyntax {
        let expression = try constExprExpression(contextualizedByOuterType: false)
        let parsed = Parser.parse(source: "let __constant = \(expression.description)")
        guard !ParseDiagnosticsGenerator.diagnostics(for: parsed).contains(where: {
            $0.diagMessage.severity == .error
        }),
            parsed.statements.count == 1,
            let declaration = parsed.statements.first?.item.as(VariableDeclSyntax.self),
            declaration.bindings.count == 1,
            declaration.bindings.first?.initializer != nil
        else {
            throw ConstExprValueError.notRepresentable(typeName)
        }
        return expression
    }

    func constExprExpression(
        contextualizedByOuterType: Bool
    ) throws -> ExprSyntax {
        switch payload {
        case .opaque(let value):
            guard let representable = value as? any ConstExprRepresentable else {
                throw ConstExprValueError.notRepresentable(typeName)
            }
            let expression = try representable.constExprExpression()
            let dynamicType = Swift.type(of: value)
            guard ObjectIdentifier(dynamicType) != ObjectIdentifier(staticType) else {
                return expression
            }
            if contextualizedByOuterType,
               !(value is ConstExprStructurallyErasedValue)
            {
                return expression
            }

            // Values returned as `Any`, `AnyObject`, a superclass, or a
            // protocol existential must not be emitted as a bare expression
            // of their concrete dynamic type. The explicit cast preserves the
            // declaration's static result type and therefore preserves later
            // overload resolution and inferred binding types.
            let castType: String
            if staticType == Any.self {
                castType = "Any"
            } else if staticType == AnyObject.self {
                castType = "AnyObject"
            } else if staticType is AnyClass {
                let reflectedType = explicitTypeName ?? String(reflecting: staticType)
                guard !reflectedType.contains("(unknown context at") else {
                    throw ConstExprValueError.notRepresentable(typeName)
                }
                castType = reflectedType
            } else {
                let reflectedType = String(reflecting: staticType)
                let metatypeKind = String(reflecting: Swift.type(of: staticType))
                guard metatypeKind.hasSuffix(".Protocol") else {
                    throw ConstExprValueError.notRepresentable(typeName)
                }
                if let explicitTypeName {
                    castType = explicitTypeName
                } else {
                    guard !reflectedType.contains("(unknown context at") else {
                        throw ConstExprValueError.notRepresentable(typeName)
                    }
                    castType = "any \(reflectedType)"
                }
            }
            return ExprSyntax(
                stringLiteral: "(\(expression.description)) as \(castType)"
            )

        case .optional(let wrapped):
            let type = explicitTypeName ?? typeName
            if let wrapped {
                let expression = try wrapped.constExprExpression(
                    contextualizedByOuterType: explicitTypeName != nil
                ).description
                return ExprSyntax(stringLiteral: "(\(expression)) as \(type)")
            }
            guard explicitTypeName != nil else {
                return ExprSyntax(stringLiteral: "nil")
            }
            return ExprSyntax(stringLiteral: "nil as \(type)")

        case .array(let elements):
            let rendered = try elements.map {
                try $0.constExprExpression(
                    contextualizedByOuterType: explicitTypeName != nil
                ).description
            }
                .joined(separator: ", ")
            let literal = "[\(rendered)]"
            if let explicitTypeName {
                return ExprSyntax(stringLiteral: "(\(literal)) as \(explicitTypeName)")
            }
            return ExprSyntax(stringLiteral: literal)

        case .dictionary(let entries):
            var rendered = try entries.map { entry in
                (
                    try entry.0.constExprExpression(
                        contextualizedByOuterType: explicitTypeName != nil
                    ).description,
                    try entry.1.constExprExpression(
                        contextualizedByOuterType: explicitTypeName != nil
                    ).description
                )
            }
            rendered.sort { lhs, rhs in
                lhs.0 == rhs.0 ? lhs.1 < rhs.1 : lhs.0 < rhs.0
            }
            let literal = rendered.isEmpty
                ? "[:]"
                : "[" + rendered.map { "\($0.0): \($0.1)" }.joined(separator: ", ") + "]"
            if let explicitTypeName {
                return ExprSyntax(stringLiteral: "(\(literal)) as \(explicitTypeName)")
            }
            return ExprSyntax(stringLiteral: literal)

        case .tuple(let elements):
            let body = try elements.map { element in
                let value = try element.value.constExprExpression(
                    contextualizedByOuterType: explicitTypeName != nil
                ).description
                return element.label.map { "\($0): \(value)" } ?? value
            }.joined(separator: ", ")
            let literal: String
            if elements.count == 1 {
                // Swift has no one-element tuple type; retain grouping syntax.
                literal = "(\(body))"
            } else {
                literal = "(\(body))"
            }
            if let explicitTypeName {
                return ExprSyntax(stringLiteral: "(\(literal)) as \(explicitTypeName)")
            }
            return ExprSyntax(stringLiteral: literal)
        }
    }

    /// Compatibility property for callers that prefer a best-effort result.
    public var renderedSource: String? {
        try? constExprExpression().description
    }

    public func renderSource() throws -> String {
        try constExprExpression().description
    }

    public func sourceExpression() throws -> ExprSyntax {
        try constExprExpression()
    }

    func renderedExpression() throws -> ExprSyntax {
        try constExprExpression()
    }

    private func raw<T>(as type: T.Type) -> T? {
        guard hasRawValue, let rawValue else { return nil }
        return rawValue as? T
    }

    private func convertedScalar<T>(to type: T.Type) -> T? {
        if let exact = raw(as: T.self) { return exact }
        guard let converted = literalConverted(to: T.self) else { return nil }
        return converted.raw(as: T.self)
    }

    fileprivate func requireScalar<T>(_ type: T.Type) throws -> T {
        if let value: T = convertedScalar(to: type) {
            return value
        }
        throw ConstExprValueError.typeMismatch(
            expected: String(reflecting: T.self),
            actual: typeName
        )
    }

    fileprivate var optionalPayload: ConstExprValue?? {
        guard case .optional(let value) = payload else { return nil }
        return .some(value)
    }

    fileprivate var arrayPayload: [ConstExprValue]? {
        guard case .array(let values) = payload else { return nil }
        return values
    }

    fileprivate var dictionaryPayload: [(ConstExprValue, ConstExprValue)]? {
        guard case .dictionary(let entries) = payload else { return nil }
        return entries
    }
}

private func integerExpression<T: FixedWidthInteger>(_ value: T, type: T.Type) -> ExprSyntax {
    let literal = String(value)
    if T.self == Int.self {
        return ExprSyntax(stringLiteral: literal)
    }
    return ExprSyntax(stringLiteral: "(\(literal)) as \(String(reflecting: T.self))")
}

private func escapedSwiftString(_ value: String) -> String {
    var result = "\""
    for scalar in value.unicodeScalars {
        switch scalar.value {
        case 0x00:
            result += "\\0"
        case 0x09:
            result += "\\t"
        case 0x0A:
            result += "\\n"
        case 0x0D:
            result += "\\r"
        case 0x22:
            result += "\\\""
        case 0x5C:
            result += "\\\\"
        case 0x01...0x08, 0x0B, 0x0C, 0x0E...0x1F, 0x7F:
            result += "\\u{\(String(scalar.value, radix: 16))}"
        default:
            result.unicodeScalars.append(scalar)
        }
    }
    result += "\""
    return result
}

extension Int: ConstExprRepresentable, ConstExprValueDecodable {
    public func constExprExpression() throws -> ExprSyntax { integerExpression(self, type: Self.self) }
    public static func decodeConstExprValue(_ value: ConstExprValue) throws -> Self { try value.requireScalar(Self.self) }
}
extension Int8: ConstExprRepresentable, ConstExprValueDecodable {
    public func constExprExpression() throws -> ExprSyntax { integerExpression(self, type: Self.self) }
    public static func decodeConstExprValue(_ value: ConstExprValue) throws -> Self { try value.requireScalar(Self.self) }
}
extension Int16: ConstExprRepresentable, ConstExprValueDecodable {
    public func constExprExpression() throws -> ExprSyntax { integerExpression(self, type: Self.self) }
    public static func decodeConstExprValue(_ value: ConstExprValue) throws -> Self { try value.requireScalar(Self.self) }
}
extension Int32: ConstExprRepresentable, ConstExprValueDecodable {
    public func constExprExpression() throws -> ExprSyntax { integerExpression(self, type: Self.self) }
    public static func decodeConstExprValue(_ value: ConstExprValue) throws -> Self { try value.requireScalar(Self.self) }
}
extension Int64: ConstExprRepresentable, ConstExprValueDecodable {
    public func constExprExpression() throws -> ExprSyntax { integerExpression(self, type: Self.self) }
    public static func decodeConstExprValue(_ value: ConstExprValue) throws -> Self { try value.requireScalar(Self.self) }
}
extension UInt: ConstExprRepresentable, ConstExprValueDecodable {
    public func constExprExpression() throws -> ExprSyntax { integerExpression(self, type: Self.self) }
    public static func decodeConstExprValue(_ value: ConstExprValue) throws -> Self { try value.requireScalar(Self.self) }
}
extension UInt8: ConstExprRepresentable, ConstExprValueDecodable {
    public func constExprExpression() throws -> ExprSyntax { integerExpression(self, type: Self.self) }
    public static func decodeConstExprValue(_ value: ConstExprValue) throws -> Self { try value.requireScalar(Self.self) }
}
extension UInt16: ConstExprRepresentable, ConstExprValueDecodable {
    public func constExprExpression() throws -> ExprSyntax { integerExpression(self, type: Self.self) }
    public static func decodeConstExprValue(_ value: ConstExprValue) throws -> Self { try value.requireScalar(Self.self) }
}
extension UInt32: ConstExprRepresentable, ConstExprValueDecodable {
    public func constExprExpression() throws -> ExprSyntax { integerExpression(self, type: Self.self) }
    public static func decodeConstExprValue(_ value: ConstExprValue) throws -> Self { try value.requireScalar(Self.self) }
}
extension UInt64: ConstExprRepresentable, ConstExprValueDecodable {
    public func constExprExpression() throws -> ExprSyntax { integerExpression(self, type: Self.self) }
    public static func decodeConstExprValue(_ value: ConstExprValue) throws -> Self { try value.requireScalar(Self.self) }
}

extension Bool: ConstExprRepresentable, ConstExprValueDecodable {
    public func constExprExpression() throws -> ExprSyntax {
        ExprSyntax(stringLiteral: self ? "true" : "false")
    }
    public static func decodeConstExprValue(_ value: ConstExprValue) throws -> Self { try value.requireScalar(Self.self) }
}

extension Double: ConstExprRepresentable, ConstExprValueDecodable {
    public func constExprExpression() throws -> ExprSyntax {
        if isNaN {
            return ExprSyntax(stringLiteral: "Swift.Double(bitPattern: \(bitPattern))")
        }
        if self == .infinity { return ExprSyntax(stringLiteral: "Swift.Double.infinity") }
        if self == -.infinity { return ExprSyntax(stringLiteral: "-Swift.Double.infinity") }
        return ExprSyntax(stringLiteral: String(self))
    }
    public static func decodeConstExprValue(_ value: ConstExprValue) throws -> Self { try value.requireScalar(Self.self) }
}

extension Float: ConstExprRepresentable, ConstExprValueDecodable {
    public func constExprExpression() throws -> ExprSyntax {
        let body: String
        if isNaN { body = "Swift.Float(bitPattern: \(bitPattern))" }
        else if self == .infinity { body = "Swift.Float.infinity" }
        else if self == -.infinity { body = "-Swift.Float.infinity" }
        else { body = String(self) }
        if body.hasPrefix("Swift.") || body.hasPrefix("-Swift.") {
            return ExprSyntax(stringLiteral: body)
        }
        return ExprSyntax(stringLiteral: "(\(body)) as Swift.Float")
    }
    public static func decodeConstExprValue(_ value: ConstExprValue) throws -> Self { try value.requireScalar(Self.self) }
}

extension String: ConstExprRepresentable, ConstExprValueDecodable {
    public func constExprExpression() throws -> ExprSyntax {
        ExprSyntax(stringLiteral: escapedSwiftString(self))
    }
    public static func decodeConstExprValue(_ value: ConstExprValue) throws -> Self { try value.requireScalar(Self.self) }
}

extension Character: ConstExprRepresentable, ConstExprValueDecodable {
    public func constExprExpression() throws -> ExprSyntax {
        ExprSyntax(stringLiteral: "(\(escapedSwiftString(String(self)))) as Swift.Character")
    }
    public static func decodeConstExprValue(_ value: ConstExprValue) throws -> Self { try value.requireScalar(Self.self) }
}

extension Optional: ConstExprRepresentable where Wrapped: ConstExprRepresentable {
    public func constExprExpression() throws -> ExprSyntax {
        let typeName = String(reflecting: Self.self)
        switch self {
        case .none:
            return ExprSyntax(stringLiteral: "nil as \(typeName)")
        case .some(let value):
            return ExprSyntax(
                stringLiteral: "(\(try value.constExprExpression().description)) as \(typeName)"
            )
        }
    }
}

extension Optional: ConstExprOptionalTypeMetadata {
    fileprivate static var constExprWrappedType: Any.Type { Wrapped.self }

    fileprivate static func constExprNilValue() -> ConstExprValue {
        ConstExprValue.optional(nil, wrappedType: Wrapped.self)
    }

    fileprivate static func constExprWrappedValue(from value: Any) -> ConstExprValue? {
        guard let wrapped = value as? Wrapped else { return nil }
        return ConstExprValue.classified(
            wrapped,
            staticType: Wrapped.self,
            literalKind: nil
        )
    }
}

extension Optional: ConstExprValueDecodable where Wrapped: ConstExprValueDecodable {
    public static func decodeConstExprValue(_ value: ConstExprValue) throws -> Self {
        guard let optional = value.optionalPayload else {
            if case .opaque(let opaque) = value.payload, let exact = opaque as? Self { return exact }
            // Swift permits a `Wrapped` expression wherever `Wrapped?` is
            // expected. Preserve that optional-injection conversion for
            // generated adapters, including recursively nested optionals.
            return try Wrapped.decodeConstExprValue(value)
        }
        guard let wrapped = optional else { return nil }
        return try Wrapped.decodeConstExprValue(wrapped)
    }
}

extension Optional: ConstExprStructuralValueDecodable {
    fileprivate static func decodeStructuralConstExprValue(
        _ value: ConstExprValue
    ) throws -> Any {
        guard let optional = value.optionalPayload else {
            return Self.some(try value.require(Wrapped.self)) as Any
        }
        guard let wrapped = optional else { return Self.none as Any }
        return Self.some(try wrapped.require(Wrapped.self)) as Any
    }
}

extension Array: ConstExprRepresentable where Element: ConstExprRepresentable {
    public func constExprExpression() throws -> ExprSyntax {
        let body = try map { try $0.constExprExpression().description }.joined(separator: ", ")
        return ExprSyntax(
            stringLiteral: "([\(body)]) as \(String(reflecting: Self.self))"
        )
    }
}

extension Array: ConstExprArrayTypeMetadata {
    fileprivate static var constExprElementType: Any.Type { Element.self }

    fileprivate static func constExprElements(from value: Any) -> [ConstExprValue]? {
        guard let array = value as? Self else { return nil }
        return array.map {
            ConstExprValue.classified($0 as Any, staticType: Element.self, literalKind: nil)
        }
    }
}

extension Array: ConstExprStandardArrayLiteralTypeMetadata {
    fileprivate static var constExprArrayLiteralElementType: Any.Type {
        Element.self
    }

    fileprivate static func constExprArrayLiteralValue(
        from elements: [ConstExprValue],
        sourceTypeName: String
    ) throws -> ConstExprValue {
        // Keep parser-built arrays structural so optional/existential element
        // erasure retains the source-static casts of every child. Exact arrays
        // are materialized lazily by `require` when a registration consumes
        // the value.
        guard !elements.isEmpty else { return ConstExprValue(Self()) }
        return ConstExprValue.array(elements, typeName: sourceTypeName)
    }
}

extension Array: ConstExprValueDecodable where Element: ConstExprValueDecodable {
    public static func decodeConstExprValue(_ value: ConstExprValue) throws -> Self {
        if case .opaque(let opaque) = value.payload, let exact = opaque as? Self { return exact }
        guard let elements = value.arrayPayload else {
            throw ConstExprValueError.typeMismatch(
                expected: String(reflecting: Self.self),
                actual: value.typeName
            )
        }
        return try elements.map(Element.decodeConstExprValue)
    }
}

extension Array: ConstExprStructuralValueDecodable {
    fileprivate static func decodeStructuralConstExprValue(
        _ value: ConstExprValue
    ) throws -> Any {
        if case .opaque(let opaque) = value.payload, let exact = opaque as? Self {
            return exact
        }
        guard let elements = value.arrayPayload else {
            throw ConstExprValueError.typeMismatch(
                expected: String(reflecting: Self.self),
                actual: value.typeName
            )
        }
        return try elements.map { try $0.require(Element.self) }
    }
}

extension Set: ConstExprStandardArrayLiteralTypeMetadata {
    fileprivate static var constExprArrayLiteralElementType: Any.Type {
        Element.self
    }

    fileprivate static func constExprArrayLiteralValue(
        from elements: [ConstExprValue],
        sourceTypeName _: String
    ) throws -> ConstExprValue {
        var result: Self = []
        for element in elements {
            result.insert(try element.require(Element.self))
        }
        return ConstExprValue(result)
    }
}

extension Set: ConstExprRepresentable where Element: ConstExprRepresentable {
    public func constExprExpression() throws -> ExprSyntax {
        let elements = try map { try $0.constExprExpression().description }.sorted()
        return ExprSyntax(
            stringLiteral: "Swift.Set([\(elements.joined(separator: ", "))]) as \(String(reflecting: Self.self))"
        )
    }
}

extension Dictionary: ConstExprRepresentable
where Key: ConstExprRepresentable, Value: ConstExprRepresentable {
    public func constExprExpression() throws -> ExprSyntax {
        var entries = try map {
            (try $0.key.constExprExpression().description, try $0.value.constExprExpression().description)
        }
        entries.sort { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }
        let body = entries.map { "\($0.0): \($0.1)" }.joined(separator: ", ")
        let literal = entries.isEmpty ? "[:]" : "[\(body)]"
        return ExprSyntax(
            stringLiteral: "(\(literal)) as \(String(reflecting: Self.self))"
        )
    }
}

extension Dictionary: ConstExprDictionaryTypeMetadata {
    fileprivate static var constExprKeyType: Any.Type { Key.self }
    fileprivate static var constExprValueType: Any.Type { Value.self }

    fileprivate static func constExprEntries(
        from value: Any
    ) -> [(ConstExprValue, ConstExprValue)]? {
        guard let dictionary = value as? Self else { return nil }
        return dictionary.map {
            (
                ConstExprValue.classified($0.key as Any, staticType: Key.self, literalKind: nil),
                ConstExprValue.classified($0.value as Any, staticType: Value.self, literalKind: nil)
            )
        }
    }
}

extension Dictionary: ConstExprValueDecodable
where Key: ConstExprValueDecodable & Hashable, Value: ConstExprValueDecodable {
    public static func decodeConstExprValue(_ value: ConstExprValue) throws -> Self {
        if case .opaque(let opaque) = value.payload, let exact = opaque as? Self { return exact }
        guard let entries = value.dictionaryPayload else {
            throw ConstExprValueError.typeMismatch(
                expected: String(reflecting: Self.self),
                actual: value.typeName
            )
        }
        var result: Self = [:]
        for entry in entries {
            result[try Key.decodeConstExprValue(entry.0)] = try Value.decodeConstExprValue(entry.1)
        }
        return result
    }
}

extension Dictionary: ConstExprStructuralValueDecodable {
    fileprivate static func decodeStructuralConstExprValue(
        _ value: ConstExprValue
    ) throws -> Any {
        if case .opaque(let opaque) = value.payload, let exact = opaque as? Self {
            return exact
        }
        guard let entries = value.dictionaryPayload else {
            throw ConstExprValueError.typeMismatch(
                expected: String(reflecting: Self.self),
                actual: value.typeName
            )
        }
        var result: Self = [:]
        for entry in entries {
            result[try entry.0.require(Key.self)] = try entry.1.require(Value.self)
        }
        return result
    }
}
