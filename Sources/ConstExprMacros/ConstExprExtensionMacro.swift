import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

public struct ConstExprMembersMacro: MemberMacro {
    public static func expansion(
        of attribute: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let extensionDecl = declaration.as(ExtensionDeclSyntax.self) else {
            ConstExprMacroDiagnostic.error(
                "@ConstExprMembers can only be attached to an extension",
                id: "members-requires-extension",
                at: attribute,
                in: context
            )
            return []
        }
        if case .argumentList(let arguments) = attribute.arguments,
           arguments.contains(where: {
               $0.label?.constExprIdentifier == "named"
           })
        {
            guard let name = ConstExprMacro.namedExtensionName(
                from: attribute,
                in: context
            ) else { return [] }
            return ConstExprMacro.expandNamedExtensionMembers(
                extensionDecl,
                name: name,
                registrationAccess: ConstExprRegistrationAccessOption(
                    attribute: attribute,
                    in: context
                ),
                attribute: attribute,
                in: context
            )
        }
        guard extensionDecl.genericWhereClause == nil else { return [] }
        let genericArguments = ConstExprGenericArgumentVisitor()
        genericArguments.walk(extensionDecl.extendedType)
        guard !genericArguments.found else { return [] }

        let registrationAccess = ConstExprRegistrationAccessOption(
            attribute: attribute,
            in: context
        )
        let memberContext = ConstExprDirectMemberContext(
            extensionDecl: extensionDecl
        )
        let inheritedAttributes = extensionDecl.attributes.filter {
            guard let attribute = $0.as(AttributeSyntax.self) else { return false }
            let name = attribute.attributeName.constExprSource
            return name == "available" || name == "_spi"
        }
        var peers: [DeclSyntax] = []

        for item in extensionDecl.memberBlock.members {
            let declaration = item.decl
            let attributes = declaration.constExprAttributes
            if attributes.constExprContainsAttribute(named: "ConstExprIgnored")
                || attributes.constExprContainsAttribute(named: "ConstExpr")
            {
                continue
            }
            let metadata = ConstExprRegistrationMetadataSource(
                attributes: attributes
            )
            if metadata.isUnconditionallyUnavailable
                || metadata.hasDeprecatedAvailability
                || metadata.hasObsoletedAvailability
            {
                continue
            }

            let generated = ConstExprMacroDiagnostic.suppressing {
                extensionPeers(
                    for: declaration,
                    inheritedAttributes: inheritedAttributes,
                    memberContext: memberContext,
                    registrationAccess: registrationAccess,
                    attribute: attribute,
                    in: context
                )
            }
            peers.append(contentsOf: generated)
        }

        return peers
    }

    private static func extensionPeers(
        for declaration: DeclSyntax,
        inheritedAttributes: AttributeListSyntax,
        memberContext: ConstExprDirectMemberContext,
        registrationAccess: ConstExprRegistrationAccessOption,
        attribute: AttributeSyntax,
        in context: some MacroExpansionContext
    ) -> [DeclSyntax] {
        if var initializer = declaration.as(InitializerDeclSyntax.self) {
            initializer.attributes = merged(
                inheritedAttributes,
                initializer.attributes
            )
            return ConstExprMacro.expandDirectMember(
                initializer: initializer,
                memberContext: memberContext,
                registrationAccess: registrationAccess,
                attribute: attribute,
                in: context
            )
        }
        if var function = declaration.as(FunctionDeclSyntax.self) {
            function.attributes = merged(inheritedAttributes, function.attributes)
            return ConstExprMacro.expandDirectMember(
                function: function,
                memberContext: memberContext,
                registrationAccess: registrationAccess,
                attribute: attribute,
                in: context
            )
        }
        if var variable = declaration.as(VariableDeclSyntax.self) {
            variable.attributes = merged(inheritedAttributes, variable.attributes)
            return ConstExprMacro.expandDirectMember(
                variable: variable,
                memberContext: memberContext,
                registrationAccess: registrationAccess,
                attribute: attribute,
                in: context
            )
        }
        if var subscriptDecl = declaration.as(SubscriptDeclSyntax.self) {
            subscriptDecl.attributes = merged(
                inheritedAttributes,
                subscriptDecl.attributes
            )
            return ConstExprMacro.expandDirectMember(
                subscriptDecl: subscriptDecl,
                memberContext: memberContext,
                registrationAccess: registrationAccess,
                attribute: attribute,
                in: context
            )
        }
        if var structure = declaration.as(StructDeclSyntax.self) {
            structure.attributes = merged(inheritedAttributes, structure.attributes)
            return expandNested(
                structure,
                registrationAccess: registrationAccess,
                attribute: attribute,
                in: context
            )
        }
        if var classDecl = declaration.as(ClassDeclSyntax.self) {
            classDecl.attributes = merged(inheritedAttributes, classDecl.attributes)
            return expandNested(
                classDecl,
                registrationAccess: registrationAccess,
                attribute: attribute,
                in: context
            )
        }
        if var enumDecl = declaration.as(EnumDeclSyntax.self) {
            enumDecl.attributes = merged(inheritedAttributes, enumDecl.attributes)
            return expandNested(
                enumDecl,
                registrationAccess: registrationAccess,
                attribute: attribute,
                in: context
            )
        }
        return []
    }

    private static func expandNested(
        _ structure: StructDeclSyntax,
        registrationAccess: ConstExprRegistrationAccessOption,
        attribute: AttributeSyntax,
        in context: some MacroExpansionContext
    ) -> [DeclSyntax] {
        ConstExprMacro.expand(
            nominalName: structure.name.constExprIdentifier,
            nominalReference: structure.name.constExprIdentifierReference,
            attributes: structure.attributes,
            modifiers: structure.modifiers,
            inheritanceClause: structure.inheritanceClause,
            members: structure.memberBlock.members,
            isGeneric: structure.genericParameterClause != nil
                || structure.genericWhereClause != nil,
            requiresFinalInstanceMembers: false,
            allowsCopiedDeprecatedStoredInitializers: true,
            registrationAccess: registrationAccess,
            attribute: attribute,
            in: context
        )
    }

    private static func expandNested(
        _ classDecl: ClassDeclSyntax,
        registrationAccess: ConstExprRegistrationAccessOption,
        attribute: AttributeSyntax,
        in context: some MacroExpansionContext
    ) -> [DeclSyntax] {
        ConstExprMacro.expand(
            nominalName: classDecl.name.constExprIdentifier,
            nominalReference: classDecl.name.constExprIdentifierReference,
            attributes: classDecl.attributes,
            modifiers: classDecl.modifiers,
            inheritanceClause: classDecl.inheritanceClause,
            members: classDecl.memberBlock.members,
            isGeneric: classDecl.genericParameterClause != nil
                || classDecl.genericWhereClause != nil,
            requiresFinalInstanceMembers: !classDecl.modifiers.constExprContains(.final),
            allowsCopiedDeprecatedStoredInitializers: false,
            registrationAccess: registrationAccess,
            attribute: attribute,
            in: context
        )
    }

    private static func expandNested(
        _ enumDecl: EnumDeclSyntax,
        registrationAccess: ConstExprRegistrationAccessOption,
        attribute: AttributeSyntax,
        in context: some MacroExpansionContext
    ) -> [DeclSyntax] {
        ConstExprMacro.expand(
            nominalName: enumDecl.name.constExprIdentifier,
            nominalReference: enumDecl.name.constExprIdentifierReference,
            attributes: enumDecl.attributes,
            modifiers: enumDecl.modifiers,
            inheritanceClause: enumDecl.inheritanceClause,
            members: enumDecl.memberBlock.members,
            isGeneric: enumDecl.genericParameterClause != nil
                || enumDecl.genericWhereClause != nil,
            requiresFinalInstanceMembers: false,
            allowsCopiedDeprecatedStoredInitializers: true,
            registrationAccess: registrationAccess,
            attribute: attribute,
            in: context
        )
    }

    private static func merged(
        _ inherited: AttributeListSyntax,
        _ direct: AttributeListSyntax
    ) -> AttributeListSyntax {
        AttributeListSyntax(Array(inherited) + Array(direct))
    }
}
