import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

struct ConstExprDirectMemberContext {
    let ownerReference: String
    let enclosingAccess: ConstExprAccessLevel?
    let inheritedDeclarationAccess: ConstExprAccessLevel?
    let requiresFinalInstanceMembers: Bool

    init?(
        lexicalContext: [Syntax],
        declaration: some DeclSyntaxProtocol
    ) {
        var skippedAttachedDeclaration = false
        var nominalNames: [String] = []
        var nearestAccess: ConstExprAccessLevel?
        var nearestOwnerRequiresFinality: Bool?

        for syntax in lexicalContext {
            if syntax.is(FunctionDeclSyntax.self)
                || syntax.is(VariableDeclSyntax.self)
                || syntax.is(InitializerDeclSyntax.self)
                || syntax.is(SubscriptDeclSyntax.self)
            {
                if !skippedAttachedDeclaration {
                    skippedAttachedDeclaration = true
                    continue
                }
                // A second callable/variable context means this is a local
                // declaration rather than a member.
                return nil
            }
            if syntax.is(ProtocolDeclSyntax.self) || syntax.is(ActorDeclSyntax.self) {
                return nil
            }
            if let extensionDecl = syntax.as(ExtensionDeclSyntax.self) {
                let nested = nominalNames.reversed().joined(separator: ".")
                self.ownerReference = [
                    extensionDecl.extendedType.constExprSource,
                    nested,
                ].filter { !$0.isEmpty }.joined(separator: ".")
                self.enclosingAccess = nearestAccess
                self.inheritedDeclarationAccess = nominalNames.isEmpty
                    ? extensionDecl.modifiers.constExprAccessLevel
                    : nil
                // SwiftSyntax cannot tell whether an arbitrary extended type is
                // a value type or a non-final class. Nested nominals encountered
                // before the extension still have a syntactically known kind.
                self.requiresFinalInstanceMembers =
                    nearestOwnerRequiresFinality ?? true
                return
            }
            if let structure = syntax.as(StructDeclSyntax.self) {
                nearestAccess = nearestAccess ?? structure.modifiers.constExprAccessLevel
                nearestOwnerRequiresFinality = nearestOwnerRequiresFinality ?? false
                nominalNames.append(structure.name.constExprIdentifierReference)
                continue
            }
            if let classDecl = syntax.as(ClassDeclSyntax.self) {
                nearestAccess = nearestAccess ?? classDecl.modifiers.constExprAccessLevel
                nearestOwnerRequiresFinality = nearestOwnerRequiresFinality
                    ?? !classDecl.modifiers.constExprContains(.final)
                nominalNames.append(classDecl.name.constExprIdentifierReference)
                continue
            }
            if let enumDecl = syntax.as(EnumDeclSyntax.self) {
                nearestAccess = nearestAccess ?? enumDecl.modifiers.constExprAccessLevel
                nearestOwnerRequiresFinality = nearestOwnerRequiresFinality ?? false
                nominalNames.append(enumDecl.name.constExprIdentifierReference)
                continue
            }
        }

        guard !nominalNames.isEmpty else { return nil }
        self.ownerReference = nominalNames.reversed().joined(separator: ".")
        self.enclosingAccess = nearestAccess
        self.inheritedDeclarationAccess = nil
        self.requiresFinalInstanceMembers = nearestOwnerRequiresFinality ?? false
    }
}

extension ConstExprMacro {
    static func expandDirectMember(
        initializer: InitializerDeclSyntax,
        memberContext: ConstExprDirectMemberContext,
        registrationAccess: ConstExprRegistrationAccessOption,
        attribute: AttributeSyntax,
        in context: some MacroExpansionContext
    ) -> [DeclSyntax] {
        let nominalContext = directNominalContext(memberContext)
        let peerLevel = registrationAccess.accessLevel(
            declarationModifiers: initializer.modifiers,
            enclosingAccess: memberContext.enclosingAccess
        )
        guard let registration = initializerRegistration(
            initializer,
            owner: memberContext.ownerReference,
            nominalContext: nominalContext,
            providerAccess: peerLevel,
            allowsAvailability: true,
            in: context
        ), case .success(let callable) = ConstExprSyntaxSupport.callableModel(
            parameters: initializer.signature.parameterClause.parameters,
            effectSpecifiers: initializer.signature.effectSpecifiers,
            returnType: TypeSyntax(
                stringLiteral: initializer.optionalMark == nil
                    ? memberContext.ownerReference
                    : "\(memberContext.ownerReference)?"
            ),
            genericParameterClause: initializer.genericParameterClause,
            genericWhereClause: initializer.genericWhereClause,
            nominalContext: nominalContext
        ) else {
            return []
        }

        return directCallablePeer(
            helperName: "init__constExpr",
            selector: ConstExprSyntaxSupport.selectorLabel(
                for: initializer.signature.parameterClause.parameters
            ),
            selectorType: ConstExprSyntaxSupport.functionType(for: callable),
            registration: registration,
            modifiers: initializer.modifiers,
            attributes: initializer.attributes,
            enclosingAccess: memberContext.enclosingAccess,
            inheritedDeclarationAccess: memberContext.inheritedDeclarationAccess,
            registrationAccess: registrationAccess
        )
    }

    static func expandDirectMember(
        function: FunctionDeclSyntax,
        memberContext: ConstExprDirectMemberContext,
        registrationAccess: ConstExprRegistrationAccessOption,
        attribute: AttributeSyntax,
        in context: some MacroExpansionContext
    ) -> [DeclSyntax] {
        let nominalContext = directNominalContext(memberContext)
        let peerLevel = registrationAccess.accessLevel(
            declarationModifiers: function.modifiers,
            enclosingAccess: memberContext.enclosingAccess
        )
        guard let registration = methodRegistration(
            function,
            owner: memberContext.ownerReference,
            nominalContext: nominalContext,
            providerAccess: peerLevel,
            requiresFinalInstanceMembers: memberContext.requiresFinalInstanceMembers,
            allowsAvailability: true,
            in: context
        ), case .success(let callable) = ConstExprSyntaxSupport.callableModel(
            parameters: function.signature.parameterClause.parameters,
            effectSpecifiers: function.signature.effectSpecifiers,
            returnType: function.signature.returnClause?.type,
            genericParameterClause: function.genericParameterClause,
            genericWhereClause: function.genericWhereClause,
            nominalContext: nominalContext
        ) else {
            return []
        }

        let isStatic = function.modifiers.constExprContains(.static)
            || function.modifiers.constExprContains(.class)
        let callableType = ConstExprSyntaxSupport.functionType(for: callable)
        let selectorType = isStatic
            ? callableType
            : "(\(memberContext.ownerReference)) -> \(callableType)"
        return directCallablePeer(
            helperName: ConstExprSyntaxSupport.synthesizedName(
                for: function.name,
                suffix: "__constExpr"
            ),
            selector: ConstExprSyntaxSupport.selectorLabel(
                for: function.signature.parameterClause.parameters
            ),
            selectorType: selectorType,
            registration: registration,
            modifiers: function.modifiers,
            attributes: function.attributes,
            enclosingAccess: memberContext.enclosingAccess,
            inheritedDeclarationAccess: memberContext.inheritedDeclarationAccess,
            registrationAccess: registrationAccess
        )
    }

    static func expandDirectMember(
        variable: VariableDeclSyntax,
        memberContext: ConstExprDirectMemberContext,
        registrationAccess: ConstExprRegistrationAccessOption,
        attribute: AttributeSyntax,
        in context: some MacroExpansionContext
    ) -> [DeclSyntax] {
        guard variable.bindings.count == 1,
              let binding = variable.bindings.first,
              let pattern = binding.pattern.as(IdentifierPatternSyntax.self),
              let typeSyntax = binding.typeAnnotation?.type
        else {
            ConstExprMacroDiagnostic.error(
                "direct @ConstExpr properties require one identifier binding with an explicit type",
                id: "unsupported-property",
                at: attribute,
                in: context
            )
            return []
        }
        let nominalContext = directNominalContext(memberContext)
        let peerLevel = registrationAccess.accessLevel(
            declarationModifiers: variable.modifiers,
            enclosingAccess: memberContext.enclosingAccess
        )
        guard let registration = propertyRegistrations(
            variable,
            owner: memberContext.ownerReference,
            nominalContext: nominalContext,
            providerAccess: peerLevel,
            requiresFinalInstanceMembers: memberContext.requiresFinalInstanceMembers,
            allowsAvailability: true,
            in: context
        ).first else {
            return []
        }

        let access = registrationAccess.accessPrefix(
            declarationModifiers: variable.modifiers,
            enclosingAccess: memberContext.enclosingAccess,
            inheritedDeclarationAccess: memberContext.inheritedDeclarationAccess
        )
        let attributes = variable.attributes.constExprPreservedPeerAttributes
        let attributePrefix = attributes.isEmpty ? "" : "\(attributes)\n"
        let helperName = ConstExprSyntaxSupport.synthesizedName(
            for: pattern.identifier,
            suffix: "__constExpr"
        )
        let selector = ConstExprSyntaxSupport.selectorLabel(for: [String]())
        let type = nominalContext.typeSource(for: typeSyntax)
        let isStatic = variable.modifiers.constExprContains(.static)
            || variable.modifiers.constExprContains(.class)
        let selectorType = isStatic
            ? "@autoclosure @escaping () -> \(type)"
            : "Swift.KeyPath<\(memberContext.ownerReference), \(type)>"
        let source = """
        \(attributePrefix)\(access)static func \(helperName)(
            \(selector) _: \(selectorType)
        ) -> \(registrationAccess.registrationArrayType) {
            [
        \(ConstExprSyntaxSupport.indent(registration, by: 8))
            ]
        }
        """
        return [DeclSyntax(stringLiteral: source)]
    }

    static func expandDirectMember(
        subscriptDecl: SubscriptDeclSyntax,
        memberContext: ConstExprDirectMemberContext,
        registrationAccess: ConstExprRegistrationAccessOption,
        attribute: AttributeSyntax,
        in context: some MacroExpansionContext
    ) -> [DeclSyntax] {
        let nominalContext = directNominalContext(memberContext)
        let peerLevel = registrationAccess.accessLevel(
            declarationModifiers: subscriptDecl.modifiers,
            enclosingAccess: memberContext.enclosingAccess
        )
        guard let registration = subscriptRegistration(
            subscriptDecl,
            owner: memberContext.ownerReference,
            nominalContext: nominalContext,
            providerAccess: peerLevel,
            requiresFinalInstanceMembers: memberContext.requiresFinalInstanceMembers,
            allowsAvailability: true,
            in: context
        ), case .success(let callable) = ConstExprSyntaxSupport.callableModel(
            parameters: subscriptDecl.parameterClause.parameters,
            effectSpecifiers: nil,
            returnType: subscriptDecl.returnClause.type,
            genericParameterClause: subscriptDecl.genericParameterClause,
            genericWhereClause: subscriptDecl.genericWhereClause,
            nominalContext: nominalContext
        ) else {
            return []
        }

        return directCallablePeer(
            helperName: "subscript__constExpr",
            selector: ConstExprSyntaxSupport.selectorLabel(
                for: subscriptDecl.parameterClause.parameters
            ),
            selectorType: "(\(ConstExprSyntaxSupport.functionType(for: callable))).Type",
            registration: registration,
            modifiers: subscriptDecl.modifiers,
            attributes: subscriptDecl.attributes,
            enclosingAccess: memberContext.enclosingAccess,
            inheritedDeclarationAccess: memberContext.inheritedDeclarationAccess,
            registrationAccess: registrationAccess,
            escapingSelector: false
        )
    }

    private static func directNominalContext(
        _ memberContext: ConstExprDirectMemberContext
    ) -> ConstExprNominalContext {
        ConstExprNominalContext(
            ownerReference: memberContext.ownerReference,
            localTypeNames: []
        )
    }

    private static func directCallablePeer(
        helperName: String,
        selector: String,
        selectorType: String,
        registration: String,
        modifiers: DeclModifierListSyntax,
        attributes: AttributeListSyntax,
        enclosingAccess: ConstExprAccessLevel?,
        inheritedDeclarationAccess: ConstExprAccessLevel?,
        registrationAccess: ConstExprRegistrationAccessOption,
        escapingSelector: Bool = true
    ) -> [DeclSyntax] {
        let access = registrationAccess.accessPrefix(
            declarationModifiers: modifiers,
            enclosingAccess: enclosingAccess,
            inheritedDeclarationAccess: inheritedDeclarationAccess
        )
        let preserved = attributes.constExprPreservedPeerAttributes
        let attributePrefix = preserved.isEmpty ? "" : "\(preserved)\n"
        let escaping = escapingSelector ? "@escaping " : ""
        let source = """
        \(attributePrefix)\(access)static func \(helperName)(
            \(selector) _: \(escaping)\(selectorType)
        ) -> \(registrationAccess.registrationArrayType) {
            [
        \(ConstExprSyntaxSupport.indent(registration, by: 8))
            ]
        }
        """
        return [DeclSyntax(stringLiteral: source)]
    }
}
