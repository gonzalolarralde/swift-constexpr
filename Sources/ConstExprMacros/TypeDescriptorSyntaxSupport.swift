import Foundation
import SwiftSyntax
import SwiftSyntaxMacros

extension ConstExprSyntaxSupport {
    static func typeDescriptorSource(
        for type: TypeSyntax,
        nominalContext: ConstExprNominalContext? = nil
    ) -> String {
        if let optional = type.as(OptionalTypeSyntax.self) {
            return "_ConstExprRuntime.StaticTypeDescriptor.optional(\(typeDescriptorSource(for: optional.wrappedType, nominalContext: nominalContext)))"
        }
        if let arguments = standardGenericArguments(
            of: type,
            named: "Optional",
            arity: 1,
            nominalContext: nominalContext
        ) {
            return "_ConstExprRuntime.StaticTypeDescriptor.optional(\(typeDescriptorSource(for: arguments[0], nominalContext: nominalContext)))"
        }
        if let array = type.as(ArrayTypeSyntax.self) {
            return "_ConstExprRuntime.StaticTypeDescriptor.array(\(typeDescriptorSource(for: array.element, nominalContext: nominalContext)))"
        }
        if let arguments = standardGenericArguments(
            of: type,
            named: "Array",
            arity: 1,
            nominalContext: nominalContext
        ) {
            return "_ConstExprRuntime.StaticTypeDescriptor.array(\(typeDescriptorSource(for: arguments[0], nominalContext: nominalContext)))"
        }
        if let dictionary = type.as(DictionaryTypeSyntax.self) {
            return "_ConstExprRuntime.StaticTypeDescriptor.dictionary(key: \(typeDescriptorSource(for: dictionary.key, nominalContext: nominalContext)), value: \(typeDescriptorSource(for: dictionary.value, nominalContext: nominalContext)))"
        }
        if let arguments = standardGenericArguments(
            of: type,
            named: "Dictionary",
            arity: 2,
            nominalContext: nominalContext
        ) {
            return "_ConstExprRuntime.StaticTypeDescriptor.dictionary(key: \(typeDescriptorSource(for: arguments[0], nominalContext: nominalContext)), value: \(typeDescriptorSource(for: arguments[1], nominalContext: nominalContext)))"
        }
        if let tuple = type.as(TupleTypeSyntax.self) {
            if tuple.elements.count == 1, let element = tuple.elements.first {
                return typeDescriptorSource(for: element.type, nominalContext: nominalContext)
            }
            let elements = tuple.elements.map {
                typeDescriptorSource(for: $0.type, nominalContext: nominalContext)
            }.joined(separator: ", ")
            return "_ConstExprRuntime.StaticTypeDescriptor.tuple([\(elements)])"
        }

        let source = nominalContext?.typeSource(for: type) ?? type.constExprSource
        let existential = type.as(SomeOrAnyTypeSyntax.self).flatMap { syntax -> String? in
            guard syntax.someOrAnySpecifier.tokenKind == .keyword(.any) else { return nil }
            return nominalContext?.typeSource(for: syntax.constraint)
                ?? syntax.constraint.constExprSource
        }
        let acceptsSourceType = existential.map {
            "{ $0 is any (\($0)).Type }"
        } ?? "nil"
        return "_ConstExprRuntime.StaticTypeDescriptor.leaf(type: \(metatypeSource(for: source)), sourceName: \(source.constExprStringLiteral), isExistential: \(existential != nil), isClassBound: \(staticallyAnyObjectSource(for: source)), acceptsSourceType: \(acceptsSourceType))"
    }

    private static func standardGenericArguments(
        of type: TypeSyntax,
        named expectedName: String,
        arity: Int,
        nominalContext: ConstExprNominalContext?
    ) -> [TypeSyntax]? {
        let clause: GenericArgumentClauseSyntax?
        if let identifier = type.as(IdentifierTypeSyntax.self),
           identifier.name.constExprIdentifier == expectedName,
           nominalContext?.localTypeNames.contains(expectedName) != true
        {
            clause = identifier.genericArgumentClause
        } else if let member = type.as(MemberTypeSyntax.self),
                  member.name.constExprIdentifier == expectedName,
                  member.baseType.constExprSource == "Swift"
        {
            clause = member.genericArgumentClause
        } else {
            return nil
        }
        guard let clause, clause.arguments.count == arity else { return nil }
        var result: [TypeSyntax] = []
        for argument in clause.arguments {
            guard case .type(let argumentType) = argument.argument else { return nil }
            result.append(argumentType)
        }
        return result
    }

    static func metatypeSource(for type: String) -> String {
        "(\(type)).self"
    }

    static func sourceTypeNameSource(for type: String?) -> String {
        type?.constExprStringLiteral ?? "nil"
    }

    static func staticallyAnyObjectSource(for type: String) -> String {
        "_ConstExprRuntime.isStaticallyAnyObject(Swift.Optional<\(type)>.none)"
    }

    static func defaultedIndicesSource(for parameters: [ConstExprParameterModel]) -> String {
        "[" + parameters.enumerated().compactMap { index, parameter in
            parameter.defaultExpression == nil ? nil : String(index)
        }.joined(separator: ", ") + "]"
    }
}
