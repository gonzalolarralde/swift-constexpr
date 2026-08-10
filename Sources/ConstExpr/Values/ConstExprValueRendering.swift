import SwiftParser
import SwiftParserDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder

extension ConstExprValue {
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

    func raw<T>(as type: T.Type) -> T? {
        guard hasRawValue, let rawValue else { return nil }
        return rawValue as? T
    }

    func convertedScalar<T>(to type: T.Type) -> T? {
        if let exact = raw(as: T.self) { return exact }
        guard let converted = literalConverted(to: T.self) else { return nil }
        return converted.raw(as: T.self)
    }

    func requireScalar<T>(_ type: T.Type) throws -> T {
        if let value: T = convertedScalar(to: type) {
            return value
        }
        throw ConstExprValueError.typeMismatch(
            expected: String(reflecting: T.self),
            actual: typeName
        )
    }

    var optionalPayload: ConstExprValue?? {
        guard case .optional(let value) = payload else { return nil }
        return .some(value)
    }

    var arrayPayload: [ConstExprValue]? {
        guard case .array(let values) = payload else { return nil }
        return values
    }

    var dictionaryPayload: [(ConstExprValue, ConstExprValue)]? {
        guard case .dictionary(let entries) = payload else { return nil }
        return entries
    }
}

func integerExpression<T: FixedWidthInteger>(_ value: T, type: T.Type) -> ExprSyntax {
    let literal = String(value)
    if T.self == Int.self {
        return ExprSyntax(stringLiteral: literal)
    }
    return ExprSyntax(stringLiteral: "(\(literal)) as \(String(reflecting: T.self))")
}

func escapedSwiftString(_ value: String) -> String {
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
