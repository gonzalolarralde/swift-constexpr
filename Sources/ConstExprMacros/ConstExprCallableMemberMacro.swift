import Foundation
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

extension ConstExprMacro {
    static func rejectUnsafeMemberAttributes(
        _ attributes: AttributeListSyntax,
        description: String,
        allowsAvailability: Bool = false,
        at node: some SyntaxProtocol,
        in context: some MacroExpansionContext
    ) -> Bool {
        if let actor = attributes.constExprGlobalActorName {
            ConstExprMacroDiagnostic.warning(
                "\(description) was not registered because @\(actor) isolation cannot be called by a synchronous adapter",
                id: "isolated-member",
                at: node,
                in: context
            )
            return true
        }
        if !allowsAvailability && attributes.constExprHasAvailabilityConstraint {
            ConstExprMacroDiagnostic.warning(
                "\(description) was not registered because member-level availability cannot be represented safely in the generated registration array",
                id: "availability-member",
                at: node,
                in: context
            )
            return true
        }
        // A public generated provider cannot expose an SPI member through its
        // unconditionally public registration array. Whole-nominal SPI is
        // safe because the peer copies the nominal's @_spi attribute.
        if attributes.constExprHasSPIConstraint {
            return true
        }
        if let attribute = attributes.constExprUnsupportedSemanticAttributeName {
            ConstExprMacroDiagnostic.warning(
                "\(description) was not registered because @\(attribute) may impose isolation or semantic transforms that a generated adapter cannot prove safe; use manual registration",
                id: "unsupported-member-attribute",
                at: node,
                in: context
            )
            return true
        }
        return false
    }

    static func hasInsufficientAccess(
        _ modifiers: DeclModifierListSyntax,
        providerAccess: ConstExprAccessLevel
    ) -> Bool {
        return modifiers.constExprAccessLevel < providerAccess
    }

    static func rejectUnsupportedDefaultAdapter(
        _ callable: ConstExprCallableModel,
        description: String,
        at node: some SyntaxProtocol,
        in context: some MacroExpansionContext
    ) -> Bool {
        guard callable.requiresManualDefaultAdapter else { return false }
        ConstExprMacroDiagnostic.warning(
            "\(description) was not registered because its \(callable.defaultCount) default arguments include a non-literal expression and exceed the automatic omission limit of eight; provide a manual label-keyed ConstExprRegistration adapter",
            id: "manual-default-adapter-required",
            at: node,
            in: context
        )
        return true
    }

    static func initializerRegistration(
        _ initializer: InitializerDeclSyntax,
        owner: String,
        nominalContext: ConstExprNominalContext,
        providerAccess: ConstExprAccessLevel,
        allowsAvailability: Bool = false,
        in context: some MacroExpansionContext
    ) -> String? {
        if rejectUnsafeMemberAttributes(
            initializer.attributes,
            description: "initializer",
            allowsAvailability: allowsAvailability,
            at: initializer,
            in: context
        ) {
            return nil
        }
        if initializer.modifiers.constExprAccessLevel == .private {
            ConstExprMacroDiagnostic.warning(
                "private initializer was not registered",
                id: "private-member",
                at: initializer,
                in: context
            )
            return nil
        }
        if hasInsufficientAccess(
            initializer.modifiers,
            providerAccess: providerAccess
        ) {
            return nil
        }
        switch ConstExprSyntaxSupport.callableModel(
            parameters: initializer.signature.parameterClause.parameters,
            effectSpecifiers: initializer.signature.effectSpecifiers,
            returnType: TypeSyntax(stringLiteral: initializer.optionalMark == nil ? owner : "\(owner)?"),
            genericParameterClause: initializer.genericParameterClause,
            genericWhereClause: initializer.genericWhereClause,
            nominalContext: nominalContext
        ) {
        case .failure(let error):
            ConstExprMacroDiagnostic.warning(
                "initializer was not registered: \(error.message)",
                id: "unsupported-member",
                at: initializer,
                in: context
            )
            return nil
        case .success(let callable):
            guard !rejectUnsupportedDefaultAdapter(
                callable,
                description: "initializer",
                at: initializer,
                in: context
            ) else { return nil }
            let names = ConstExprAdapterNames(
                parameterCount: callable.parameters.count,
                context: context
            )
            guard let invocationBody = ConstExprSyntaxSupport.memberDefaultInvocationBody(
                callable: callable,
                names: names,
                invocation: { included in
                let arguments = ConstExprSyntaxSupport.labeledCallArguments(
                    for: callable.parameters,
                    names: names,
                    including: included
                )
                return "\(callable.isThrowing ? "try " : "")\(owner)(\(arguments))"
            }) else { return nil }
            return registrationSource(
                name: owner.constExprSemanticIdentifier,
                kind: ".initializer",
                owner: owner,
                attributes: initializer.attributes,
                callable: callable,
                names: names,
                invocationBody: invocationBody,
                requiresReceiver: false
            )
        }
    }

    static func methodRegistration(
        _ function: FunctionDeclSyntax,
        owner: String,
        nominalContext: ConstExprNominalContext,
        providerAccess: ConstExprAccessLevel,
        requiresFinalInstanceMembers: Bool,
        allowsAvailability: Bool = false,
        in context: some MacroExpansionContext
    ) -> String? {
        if rejectUnsafeMemberAttributes(
            function.attributes,
            description: "method '\(function.name.constExprIdentifier)'",
            allowsAvailability: allowsAvailability,
            at: function,
            in: context
        ) {
            return nil
        }
        guard isIdentifier(function.name) else {
            ConstExprMacroDiagnostic.warning(
                "operator member was not registered; use a ConstExprRegistration operator factory",
                id: "operator-member",
                at: function,
                in: context
            )
            return nil
        }
        if function.modifiers.constExprAccessLevel == .private {
            ConstExprMacroDiagnostic.warning(
                "private method '\(function.name.constExprIdentifier)' was not registered",
                id: "private-member",
                at: function,
                in: context
            )
            return nil
        }
        if hasInsufficientAccess(
            function.modifiers,
            providerAccess: providerAccess
        ) {
            return nil
        }
        if function.modifiers.constExprContains(.dynamic) {
            ConstExprMacroDiagnostic.warning(
                "dynamic method '\(function.name.constExprIdentifier)' was not registered because runtime replacement or dispatch can invoke an unregistered implementation",
                id: "dynamic-member",
                at: function,
                in: context
            )
            return nil
        }
        let isStatic = function.modifiers.constExprContains(.static)
            || function.modifiers.constExprContains(.class)
        if requiresFinalInstanceMembers,
           !isStatic,
           !function.modifiers.constExprContains(.final)
        {
            ConstExprMacroDiagnostic.warning(
                "overridable instance method '\(function.name.constExprIdentifier)' was not registered; mark the class or member final to prevent dispatch to an unregistered override",
                id: "overridable-member",
                at: function,
                in: context
            )
            return nil
        }
        if function.modifiers.constExprContains(.mutating)
            || function.modifiers.constExprContains(.consuming)
        {
            ConstExprMacroDiagnostic.warning(
                "mutating or consuming method '\(function.name.constExprIdentifier)' was not registered",
                id: "mutating-member",
                at: function,
                in: context
            )
            return nil
        }
        switch ConstExprSyntaxSupport.callableModel(
            parameters: function.signature.parameterClause.parameters,
            effectSpecifiers: function.signature.effectSpecifiers,
            returnType: function.signature.returnClause?.type,
            genericParameterClause: function.genericParameterClause,
            genericWhereClause: function.genericWhereClause,
            nominalContext: nominalContext
        ) {
        case .failure(let error):
            ConstExprMacroDiagnostic.warning(
                "method '\(function.name.constExprIdentifier)' was not registered: \(error.message)",
                id: "unsupported-member",
                at: function,
                in: context
            )
            return nil
        case .success(let callable):
            guard !rejectUnsupportedDefaultAdapter(
                callable,
                description: "method '\(function.name.constExprIdentifier)'",
                at: function,
                in: context
            ) else { return nil }
            let names = ConstExprAdapterNames(
                parameterCount: callable.parameters.count,
                context: context
            )
            guard let invocationBody = ConstExprSyntaxSupport.memberDefaultInvocationBody(
                callable: callable,
                names: names,
                invocation: { included in
                let arguments = ConstExprSyntaxSupport.labeledCallArguments(
                    for: callable.parameters,
                    names: names,
                    including: included
                )
                let base = isStatic ? owner : names.instance
                return "\(callable.isThrowing ? "try " : "")\(base).\(function.name.constExprIdentifierReference)(\(arguments))"
            }) else { return nil }
            return registrationSource(
                name: function.name.constExprIdentifier,
                kind: isStatic ? ".staticMethod" : ".instanceMethod",
                owner: owner,
                attributes: function.attributes,
                callable: callable,
                names: names,
                invocationBody: invocationBody,
                requiresReceiver: !isStatic
            )
        }
    }

}
