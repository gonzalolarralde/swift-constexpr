import Foundation
import SwiftSyntax
import SwiftSyntaxMacros

extension ConstExprSyntaxSupport {
    static func selectorLabel(for labels: [String]) -> String {
        guard !labels.isEmpty else { return "__constExprSelector_0" }
        let encoded = labels.map { rawLabel in
            let label = rawLabel.constExprSemanticIdentifier
            return "\(label.unicodeScalars.count)_\(label)"
        }.joined(separator: "__")
        return "__constExprSelector_\(labels.count)_\(encoded)"
    }

    static func selectorLabel(for parameters: FunctionParameterListSyntax) -> String {
        selectorLabel(for: parameters.map { $0.firstName.constExprIdentifier })
    }

    static func synthesizedName(for token: TokenSyntax, suffix: String) -> String {
        token.constExprIdentifier + suffix
    }

    static func callableModel(
        parameters: FunctionParameterListSyntax,
        effectSpecifiers: FunctionEffectSpecifiersSyntax?,
        returnType: TypeSyntax?,
        genericParameterClause: GenericParameterClauseSyntax?,
        genericWhereClause: GenericWhereClauseSyntax?,
        nominalContext: ConstExprNominalContext? = nil
    ) -> Result<ConstExprCallableModel, ConstExprModelError> {
        if genericParameterClause != nil || genericWhereClause != nil {
            return .failure(.init(message: "generic declarations are not supported by @ConstExpr"))
        }
        if effectSpecifiers?.asyncSpecifier != nil {
            return .failure(.init(message: "async declarations are not supported by @ConstExpr"))
        }
        if effectSpecifiers?.throwsClause?.throwsSpecifier.text == "rethrows" {
            return .failure(.init(message: "rethrows declarations are not supported by @ConstExpr"))
        }
        if effectSpecifiers?.throwsClause?.type != nil {
            return .failure(.init(message: "typed throws declarations are not supported by @ConstExpr"))
        }

        let resultSyntax = returnType ?? TypeSyntax(stringLiteral: "Void")
        if let error = unsupportedTypeError(resultSyntax, role: "result") {
            return .failure(error)
        }
        let resultType = nominalContext?.typeSource(for: resultSyntax) ?? resultSyntax.constExprSource
        if resultType == "Void" || resultType == "()" || resultType == "Never" {
            return .failure(.init(message: "@ConstExpr callables must return a value"))
        }

        var models: [ConstExprParameterModel] = []
        for parameter in parameters {
            if parameter.ellipsis != nil {
                return .failure(.init(message: "variadic parameters are not supported by @ConstExpr"))
            }
            if parameter.attributes.constExprSource.contains("@autoclosure") {
                return .failure(.init(message: "@autoclosure parameters are not supported by @ConstExpr"))
            }
            if let error = unsupportedTypeError(parameter.type, role: "parameter") {
                return .failure(error)
            }

            let defaultExpression = parameter.defaultValue?.value.constExprSource
            if let defaultValue = parameter.defaultValue?.value,
               containsCallerLocation(defaultValue)
            {
                return .failure(.init(message: "caller-location default arguments are not supported by @ConstExpr"))
            }
            models.append(
                ConstExprParameterModel(
                    label: parameter.firstName.constExprIdentifier == "_"
                        ? nil
                        : parameter.firstName.constExprIdentifier,
                    invocationLabel: parameter.firstName.constExprIdentifier == "_"
                        ? nil
                        // Keywords are accepted unescaped in argument-label
                        // position; retaining declaration backticks emits a
                        // compiler warning (and breaks warnings-as-errors).
                        : parameter.firstName.constExprIdentifier,
                    type: nominalContext?.typeSource(for: parameter.type)
                        ?? parameter.type.constExprSource,
                    typeDescriptor: typeDescriptorSource(
                        for: parameter.type,
                        nominalContext: nominalContext
                    ),
                    defaultExpression: defaultExpression,
                    defaultIsSelfContainedLiteral: parameter.defaultValue.map {
                        isSelfContainedDefaultLiteral($0.value)
                    } ?? false
                )
            )
        }

        return .success(
            ConstExprCallableModel(
                parameters: models,
                resultType: resultType,
                resultTypeDescriptor: typeDescriptorSource(
                    for: resultSyntax,
                    nominalContext: nominalContext
                ),
                isThrowing: effectSpecifiers?.throwsClause != nil
            )
        )
    }

    static func validatedValueType(
        _ type: TypeSyntax,
        nominalContext: ConstExprNominalContext? = nil
    ) -> Result<String, ConstExprModelError> {
        if let error = unsupportedTypeError(type, role: "value") {
            return .failure(error)
        }
        let source = nominalContext?.typeSource(for: type) ?? type.constExprSource
        if source == "Void" || source == "()" || source == "Never" {
            return .failure(.init(message: "the value type must be representable"))
        }
        return .success(source)
    }

    static func containsCallerLocation(_ expression: ExprSyntax) -> Bool {
        let visitor = ConstExprCallerLocationVisitor()
        visitor.walk(expression)
        return visitor.found
    }

    /// Uses tokens instead of `AccessorDeclSyntax.modifier`, whose singular
    /// compatibility property is deprecated in newer SwiftSyntax releases.
    /// Stopping at the accessor specifier excludes tokens in the getter body.
    static func hasMutatingOrConsumingModifier(
        _ accessor: AccessorDeclSyntax
    ) -> Bool {
        accessor.tokens(viewMode: .sourceAccurate).prefix {
            $0.id != accessor.accessorSpecifier.id
        }.contains {
            $0.tokenKind == .keyword(.mutating)
                || $0.tokenKind == .keyword(.consuming)
        }
    }

    static func isSelfContainedDefaultLiteral(_ expression: ExprSyntax) -> Bool {
        if expression.is(NilLiteralExprSyntax.self)
            || expression.is(BooleanLiteralExprSyntax.self)
            || expression.is(IntegerLiteralExprSyntax.self)
            || expression.is(FloatLiteralExprSyntax.self)
        {
            return true
        }
        if let string = expression.as(StringLiteralExprSyntax.self) {
            return string.segments.allSatisfy { $0.is(StringSegmentSyntax.self) }
        }
        if let array = expression.as(ArrayExprSyntax.self) {
            return array.elements.allSatisfy {
                isSelfContainedDefaultLiteral($0.expression)
            }
        }
        if let dictionary = expression.as(DictionaryExprSyntax.self) {
            switch dictionary.content {
            case .colon:
                return true
            case .elements(let elements):
                return elements.allSatisfy {
                    isSelfContainedDefaultLiteral($0.key)
                        && isSelfContainedDefaultLiteral($0.value)
                }
            @unknown default:
                return false
            }
        }
        if let tuple = expression.as(TupleExprSyntax.self) {
            return tuple.elements.allSatisfy {
                isSelfContainedDefaultLiteral($0.expression)
            }
        }
        if let prefix = expression.as(PrefixOperatorExprSyntax.self),
           prefix.operator.text == "+" || prefix.operator.text == "-"
        {
            return prefix.expression.is(IntegerLiteralExprSyntax.self)
                || prefix.expression.is(FloatLiteralExprSyntax.self)
        }
        return false
    }

    /// Recognizes a deliberately narrow expression subset that can be copied
    /// into a generated, contextually typed static-property adapter. Leading
    /// `.init(...)` is permitted because the surrounding explicit property
    /// type fixes its owner; arbitrary references and calls remain excluded.
    static func isRecursivelySelfContainedConstantInitializer(
        _ expression: ExprSyntax
    ) -> Bool {
        if isSelfContainedDefaultLiteral(expression) { return true }
        if let array = expression.as(ArrayExprSyntax.self) {
            return array.elements.allSatisfy {
                isRecursivelySelfContainedConstantInitializer($0.expression)
            }
        }
        if let dictionary = expression.as(DictionaryExprSyntax.self) {
            switch dictionary.content {
            case .colon:
                return true
            case .elements(let elements):
                return elements.allSatisfy {
                    isRecursivelySelfContainedConstantInitializer($0.key)
                        && isRecursivelySelfContainedConstantInitializer($0.value)
                }
            @unknown default:
                return false
            }
        }
        if let tuple = expression.as(TupleExprSyntax.self) {
            return tuple.elements.allSatisfy {
                isRecursivelySelfContainedConstantInitializer($0.expression)
            }
        }
        guard let call = expression.as(FunctionCallExprSyntax.self),
              call.trailingClosure == nil,
              call.additionalTrailingClosures.isEmpty,
              let member = call.calledExpression.as(MemberAccessExprSyntax.self),
              member.base == nil,
              member.declName.baseName.constExprIdentifier == "init"
        else { return false }
        return call.arguments.allSatisfy {
            isRecursivelySelfContainedConstantInitializer($0.expression)
        }
    }

    private static func unsupportedTypeError(
        _ type: TypeSyntax,
        role: String
    ) -> ConstExprModelError? {
        let visitor = ConstExprUnsupportedTypeVisitor()
        visitor.walk(type)
        switch visitor.unsupported {
        case .function:
            return .init(message: role == "result"
                ? "function and opaque result types are not supported by @ConstExpr"
                : "function-typed \(role)s are not supported by @ConstExpr")
        case .opaque:
            return .init(message: role == "result"
                ? "function and opaque result types are not supported by @ConstExpr"
                : "opaque \(role) types are not supported by @ConstExpr")
        case .parameterizedExistential:
            return .init(
                message: "parameterized existential \(role) types require macOS 13 or newer and are not supported by @ConstExpr's macOS 11 deployment target"
            )
        case .implicitlyUnwrappedOptional:
            return .init(message: "implicitly unwrapped optional \(role) types are not supported by @ConstExpr")
        case .inoutSpecifier:
            return .init(message: "inout parameters are not supported by @ConstExpr")
        case .ownershipSpecifier(let specifier):
            return .init(message: "'\(specifier)' \(role) specifiers are not supported by @ConstExpr")
        case .attributed(let attribute):
            if attribute == "@autoclosure" {
                return .init(message: "@autoclosure parameters are not supported by @ConstExpr")
            }
            return .init(message: "attributed \(role) types are not supported by @ConstExpr")
        case nil:
            return nil
        }
    }

}
