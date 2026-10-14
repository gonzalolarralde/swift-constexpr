import ConstExpr
import SwiftSyntax
import SwiftSyntaxBuilder

extension Int: ConstExprRepresentable {
    public func constExprExpression() throws -> ExprSyntax { integerExpression(self, type: Self.self) }
}

extension Int8: ConstExprRepresentable {
    public func constExprExpression() throws -> ExprSyntax { integerExpression(self, type: Self.self) }
}

extension Int16: ConstExprRepresentable {
    public func constExprExpression() throws -> ExprSyntax { integerExpression(self, type: Self.self) }
}

extension Int32: ConstExprRepresentable {
    public func constExprExpression() throws -> ExprSyntax { integerExpression(self, type: Self.self) }
}

extension Int64: ConstExprRepresentable {
    public func constExprExpression() throws -> ExprSyntax { integerExpression(self, type: Self.self) }
}

extension UInt: ConstExprRepresentable {
    public func constExprExpression() throws -> ExprSyntax { integerExpression(self, type: Self.self) }
}

extension UInt8: ConstExprRepresentable {
    public func constExprExpression() throws -> ExprSyntax { integerExpression(self, type: Self.self) }
}

extension UInt16: ConstExprRepresentable {
    public func constExprExpression() throws -> ExprSyntax { integerExpression(self, type: Self.self) }
}

extension UInt32: ConstExprRepresentable {
    public func constExprExpression() throws -> ExprSyntax { integerExpression(self, type: Self.self) }
}

extension UInt64: ConstExprRepresentable {
    public func constExprExpression() throws -> ExprSyntax { integerExpression(self, type: Self.self) }
}


extension Bool: ConstExprRepresentable {
    public func constExprExpression() throws -> ExprSyntax {
        ExprSyntax(stringLiteral: self ? "true" : "false")
    }
}


extension Double: ConstExprRepresentable {
    public func constExprExpression() throws -> ExprSyntax {
        if isNaN {
            return ExprSyntax(stringLiteral: "Swift.Double(bitPattern: \(bitPattern))")
        }
        if self == .infinity { return ExprSyntax(stringLiteral: "Swift.Double.infinity") }
        if self == -.infinity { return ExprSyntax(stringLiteral: "-Swift.Double.infinity") }
        return ExprSyntax(stringLiteral: String(self))
    }
}


extension Float: ConstExprRepresentable {
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
}


extension String: ConstExprRepresentable {
    public func constExprExpression() throws -> ExprSyntax {
        ExprSyntax(stringLiteral: escapedSwiftString(self))
    }
}


extension Character: ConstExprRepresentable {
    public func constExprExpression() throws -> ExprSyntax {
        ExprSyntax(stringLiteral: "(\(escapedSwiftString(String(self)))) as Swift.Character")
    }
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


extension Array: ConstExprRepresentable where Element: ConstExprRepresentable {
    public func constExprExpression() throws -> ExprSyntax {
        let elementType = ConstExprSourceTypeKey(sourceName: String(reflecting: Element.self))
        let body = try map {
            try contextualNumberLiteral($0, contextualType: elementType)
                ?? $0.constExprExpression().description
        }.joined(separator: ", ")
        return ExprSyntax(
            stringLiteral: "([\(body)]) as \(String(reflecting: Self.self))"
        )
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
