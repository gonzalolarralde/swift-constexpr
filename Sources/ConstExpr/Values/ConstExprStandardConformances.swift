import SwiftSyntax
import SwiftSyntaxBuilder

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

extension Array: ConstExprRepresentable where Element: ConstExprRepresentable {
    public func constExprExpression() throws -> ExprSyntax {
        let body = try map { try $0.constExprExpression().description }.joined(separator: ", ")
        return ExprSyntax(
            stringLiteral: "([\(body)]) as \(String(reflecting: Self.self))"
        )
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
