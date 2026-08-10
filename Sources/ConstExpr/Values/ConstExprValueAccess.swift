extension ConstExprValue {
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

    func tupleMismatch(expected: String, count: Int) -> ConstExprValueError {
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

    static func literal<T>(_ value: T, _ kind: ConstExprLiteralKind) -> Self {
        classified(value as Any, staticType: T.self, literalKind: kind)
    }

}
