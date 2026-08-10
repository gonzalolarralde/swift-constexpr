import SwiftSyntax
import SwiftSyntaxMacros

extension ConstExprMacro {
    static func isUnsupportedCallableContext(
        in context: some MacroExpansionContext
    ) -> Bool {
        context.lexicalContext.contains { syntax in
            syntax.is(StructDeclSyntax.self)
                || syntax.is(ClassDeclSyntax.self)
                || syntax.is(EnumDeclSyntax.self)
                || syntax.is(ActorDeclSyntax.self)
                || syntax.is(ProtocolDeclSyntax.self)
                || syntax.is(ExtensionDeclSyntax.self)
                || syntax.is(FunctionDeclSyntax.self)
                || syntax.is(InitializerDeclSyntax.self)
                || syntax.is(DeinitializerDeclSyntax.self)
                || syntax.is(SubscriptDeclSyntax.self)
                || syntax.is(AccessorDeclSyntax.self)
                || syntax.is(ClosureExprSyntax.self)
        }
    }

    static func validateNominalContext(
        attribute: AttributeSyntax,
        in context: some MacroExpansionContext
    ) -> Bool {
        for syntax in context.lexicalContext {
            if syntax.is(FunctionDeclSyntax.self)
                || syntax.is(InitializerDeclSyntax.self)
                || syntax.is(DeinitializerDeclSyntax.self)
                || syntax.is(SubscriptDeclSyntax.self)
                || syntax.is(AccessorDeclSyntax.self)
                || syntax.is(ClosureExprSyntax.self)
            {
                ConstExprMacroDiagnostic.error(
                    "@ConstExpr nominal types cannot be local declarations",
                    id: "local-nominal",
                    at: attribute,
                    in: context
                )
                return false
            }
            if syntax.is(ProtocolDeclSyntax.self) || syntax.is(ActorDeclSyntax.self) {
                ConstExprMacroDiagnostic.error(
                    "@ConstExpr nominal types are not supported in protocols or actors",
                    id: "unsupported-nominal-context",
                    at: attribute,
                    in: context
                )
                return false
            }
            if let extensionDecl = syntax.as(ExtensionDeclSyntax.self),
               !validateExtension(
                   extensionDecl,
                   lexicalContext: context.lexicalContext,
                   attribute: attribute,
                   in: context
               )
            {
                return false
            }
            if isGenericNominal(syntax) {
                ConstExprMacroDiagnostic.error(
                    "@ConstExpr nominal types cannot be nested in a generic context",
                    id: "generic-context",
                    at: attribute,
                    in: context
                )
                return false
            }
        }
        return true
    }

    static func rejectGlobalActor(
        _ attributes: AttributeListSyntax,
        at node: some SyntaxProtocol,
        in context: some MacroExpansionContext
    ) -> Bool {
        if let actor = attributes.constExprGlobalActorName {
            ConstExprMacroDiagnostic.error(
                "global-actor-isolated declarations such as @\(actor) are not supported by synchronous @ConstExpr adapters",
                id: "global-actor",
                at: node,
                in: context
            )
            return true
        }
        if let attribute = attributes.constExprUnsupportedSemanticAttributeName {
            ConstExprMacroDiagnostic.error(
                "declaration attribute @\(attribute) may impose isolation or semantic transforms that @ConstExpr cannot prove safe; use manual registration",
                id: "unsupported-declaration-attribute",
                at: node,
                in: context
            )
            return true
        }
        return false
    }

    private static func validateExtension(
        _ extensionDecl: ExtensionDeclSyntax,
        lexicalContext: [Syntax],
        attribute: AttributeSyntax,
        in context: some MacroExpansionContext
    ) -> Bool {
        let genericArguments = ConstExprGenericArgumentVisitor()
        genericArguments.walk(extensionDecl.extendedType)
        guard extensionDecl.genericWhereClause == nil, !genericArguments.found else {
            ConstExprMacroDiagnostic.error(
                "@ConstExpr nominal types cannot be nested in a constrained or generic extension",
                id: "generic-context",
                at: attribute,
                in: context
            )
            return false
        }

        // Only an immediate extension child has a provider addressable as
        // `ExtendedType.Nested__constExpr` without opening arbitrary nested
        // extension contexts.
        let hasEnclosingNominal = lexicalContext.prefix {
            $0.id != extensionDecl.id
        }.contains {
            $0.is(StructDeclSyntax.self)
                || $0.is(ClassDeclSyntax.self)
                || $0.is(EnumDeclSyntax.self)
        }
        guard !hasEnclosingNominal else {
            ConstExprMacroDiagnostic.error(
                "@ConstExpr nominal types must be nested directly in a nongeneric, unconstrained extension",
                id: "unsupported-nominal-context",
                at: attribute,
                in: context
            )
            return false
        }
        return true
    }

    private static func isGenericNominal(_ syntax: Syntax) -> Bool {
        if let structure = syntax.as(StructDeclSyntax.self) {
            return structure.genericParameterClause != nil
                || structure.genericWhereClause != nil
        }
        if let classDecl = syntax.as(ClassDeclSyntax.self) {
            return classDecl.genericParameterClause != nil
                || classDecl.genericWhereClause != nil
        }
        if let enumDecl = syntax.as(EnumDeclSyntax.self) {
            return enumDecl.genericParameterClause != nil
                || enumDecl.genericWhereClause != nil
        }
        return false
    }
}
