#if !hasFeature(Embedded)
extension Int: ConstExprValueDecodable {
    public static func decodeConstExprValue(_ value: ConstExprValue) throws -> Self { try value.requireScalar(Self.self) }
}

extension Int8: ConstExprValueDecodable {
    public static func decodeConstExprValue(_ value: ConstExprValue) throws -> Self { try value.requireScalar(Self.self) }
}

extension Int16: ConstExprValueDecodable {
    public static func decodeConstExprValue(_ value: ConstExprValue) throws -> Self { try value.requireScalar(Self.self) }
}

extension Int32: ConstExprValueDecodable {
    public static func decodeConstExprValue(_ value: ConstExprValue) throws -> Self { try value.requireScalar(Self.self) }
}

extension Int64: ConstExprValueDecodable {
    public static func decodeConstExprValue(_ value: ConstExprValue) throws -> Self { try value.requireScalar(Self.self) }
}

extension UInt: ConstExprValueDecodable {
    public static func decodeConstExprValue(_ value: ConstExprValue) throws -> Self { try value.requireScalar(Self.self) }
}

extension UInt8: ConstExprValueDecodable {
    public static func decodeConstExprValue(_ value: ConstExprValue) throws -> Self { try value.requireScalar(Self.self) }
}

extension UInt16: ConstExprValueDecodable {
    public static func decodeConstExprValue(_ value: ConstExprValue) throws -> Self { try value.requireScalar(Self.self) }
}

extension UInt32: ConstExprValueDecodable {
    public static func decodeConstExprValue(_ value: ConstExprValue) throws -> Self { try value.requireScalar(Self.self) }
}

extension UInt64: ConstExprValueDecodable {
    public static func decodeConstExprValue(_ value: ConstExprValue) throws -> Self { try value.requireScalar(Self.self) }
}

extension Bool: ConstExprValueDecodable {
    public static func decodeConstExprValue(_ value: ConstExprValue) throws -> Self { try value.requireScalar(Self.self) }
}

extension Double: ConstExprValueDecodable {
    public static func decodeConstExprValue(_ value: ConstExprValue) throws -> Self { try value.requireScalar(Self.self) }
}

extension Float: ConstExprValueDecodable {
    public static func decodeConstExprValue(_ value: ConstExprValue) throws -> Self { try value.requireScalar(Self.self) }
}

extension String: ConstExprValueDecodable {
    public static func decodeConstExprValue(_ value: ConstExprValue) throws -> Self { try value.requireScalar(Self.self) }
}

extension Character: ConstExprValueDecodable {
    public static func decodeConstExprValue(_ value: ConstExprValue) throws -> Self { try value.requireScalar(Self.self) }
}

extension Optional: ConstExprOptionalTypeMetadata {
    static var constExprWrappedType: Any.Type { Wrapped.self }

    static func constExprNilValue() -> ConstExprValue {
        ConstExprValue.optional(nil, wrappedType: Wrapped.self)
    }

    static func constExprWrappedValue(from value: Any) -> ConstExprValue? {
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
    static func decodeStructuralConstExprValue(
        _ value: ConstExprValue
    ) throws -> Any {
        guard let optional = value.optionalPayload else {
            return Self.some(try value.require(Wrapped.self)) as Any
        }
        guard let wrapped = optional else { return Self.none as Any }
        return Self.some(try wrapped.require(Wrapped.self)) as Any
    }
}


extension Array: ConstExprArrayTypeMetadata {
    static var constExprElementType: Any.Type { Element.self }

    static func constExprElements(from value: Any) -> [ConstExprValue]? {
        guard let array = value as? Self else { return nil }
        return array.map {
            ConstExprValue.classified($0 as Any, staticType: Element.self, literalKind: nil)
        }
    }
}


extension Array: ConstExprStandardArrayLiteralTypeMetadata {
    static var constExprArrayLiteralElementType: Any.Type {
        Element.self
    }

    static func constExprArrayLiteralValue(
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
    static func decodeStructuralConstExprValue(
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
    static var constExprArrayLiteralElementType: Any.Type {
        Element.self
    }

    static func constExprArrayLiteralValue(
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


extension Set: ConstExprSetTypeMetadata {
    static var constExprElementType: Any.Type { Element.self }
}


extension Dictionary: ConstExprDictionaryTypeMetadata {
    static var constExprKeyType: Any.Type { Key.self }
    static var constExprValueType: Any.Type { Value.self }

    static func constExprEntries(
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
    static func decodeStructuralConstExprValue(
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
#endif
