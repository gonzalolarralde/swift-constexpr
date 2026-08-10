import SwiftSyntax

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
    let rawValue: Any?
    let hasRawValue: Bool

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

    static func elementType(ofSetType setType: Any.Type) -> Any.Type? {
        (setType as? any ConstExprSetTypeMetadata.Type)?.constExprElementType
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

    init(
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
}
