import Foundation
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

extension ConstExprMacro {
    static func subscriptRegistration(
        _ subscriptDecl: SubscriptDeclSyntax,
        owner: String,
        nominalContext: ConstExprNominalContext,
        providerAccess: ConstExprAccessLevel,
        requiresFinalInstanceMembers: Bool,
        allowsAvailability: Bool = false,
        in context: some MacroExpansionContext
    ) -> String? {
        if rejectUnsafeMemberAttributes(
            subscriptDecl.attributes,
            description: "subscript",
            allowsAvailability: allowsAvailability,
            at: subscriptDecl,
            in: context
        ) {
            return nil
        }
        if subscriptDecl.modifiers.constExprAccessLevel == .private {
            ConstExprMacroDiagnostic.warning(
                "private subscript was not registered",
                id: "private-member",
                at: subscriptDecl,
                in: context
            )
            return nil
        }
        if hasInsufficientAccess(
            subscriptDecl.modifiers,
            providerAccess: providerAccess
        ) {
            return nil
        }
        if subscriptDecl.modifiers.constExprContains(.dynamic) {
            ConstExprMacroDiagnostic.warning(
                "dynamic subscript was not registered because runtime replacement or dispatch can invoke an unregistered implementation",
                id: "dynamic-member",
                at: subscriptDecl,
                in: context
            )
            return nil
        }
        if subscriptDecl.modifiers.constExprContains(.static)
            || subscriptDecl.modifiers.constExprContains(.class)
        {
            ConstExprMacroDiagnostic.warning(
                "static subscripts are not supported by @ConstExpr",
                id: "static-subscript",
                at: subscriptDecl,
                in: context
            )
            return nil
        }
        if requiresFinalInstanceMembers,
           !subscriptDecl.modifiers.constExprContains(.final)
        {
            ConstExprMacroDiagnostic.warning(
                "overridable instance subscript was not registered; mark the class or subscript final to prevent dispatch to an unregistered override",
                id: "overridable-member",
                at: subscriptDecl,
                in: context
            )
            return nil
        }
        if let accessors = subscriptDecl.accessorBlock?.accessors.as(AccessorDeclListSyntax.self),
           accessors.contains(where: { accessor in
               ["set", "_modify", "modify", "mutate", "unsafeMutableAddress"]
                   .contains(accessor.accessorSpecifier.text)
           })
        {
            ConstExprMacroDiagnostic.warning(
                "writable subscript was not registered",
                id: "writable-subscript",
                at: subscriptDecl,
                in: context
            )
            return nil
        }
        if let accessors = subscriptDecl.accessorBlock?.accessors.as(AccessorDeclListSyntax.self),
           accessors.contains(where: { $0.effectSpecifiers != nil })
        {
            ConstExprMacroDiagnostic.warning(
                "async or throwing subscript accessor was not registered",
                id: "effectful-subscript",
                at: subscriptDecl,
                in: context
            )
            return nil
        }
        if let accessors = subscriptDecl.accessorBlock?.accessors.as(AccessorDeclListSyntax.self),
           accessors.contains(where: { accessor in
               guard ["get", "_read", "read"].contains(accessor.accessorSpecifier.text) else {
                   return false
               }
               return ConstExprSyntaxSupport
                   .hasMutatingOrConsumingModifier(accessor)
           })
        {
            ConstExprMacroDiagnostic.warning(
                "mutating or consuming subscript getter was not registered",
                id: "mutating-getter",
                at: subscriptDecl,
                in: context
            )
            return nil
        }

        switch ConstExprSyntaxSupport.callableModel(
            parameters: subscriptDecl.parameterClause.parameters,
            effectSpecifiers: nil,
            returnType: subscriptDecl.returnClause.type,
            genericParameterClause: subscriptDecl.genericParameterClause,
            genericWhereClause: subscriptDecl.genericWhereClause,
            nominalContext: nominalContext
        ) {
        case .failure(let error):
            ConstExprMacroDiagnostic.warning(
                "subscript was not registered: \(error.message)",
                id: "unsupported-subscript",
                at: subscriptDecl,
                in: context
            )
            return nil
        case .success(let originalCallable):
            // A single subscript parameter name is local-only. An external
            // label is present only when the declaration provides two names.
            let parameters = zip(
                subscriptDecl.parameterClause.parameters,
                originalCallable.parameters
            ).map { syntax, model in
                ConstExprParameterModel(
                    label: syntax.secondName == nil || syntax.firstName.constExprIdentifier == "_"
                        ? nil
                        : syntax.firstName.constExprIdentifier,
                    invocationLabel: syntax.secondName == nil || syntax.firstName.constExprIdentifier == "_"
                        ? nil
                        : syntax.firstName.constExprIdentifier,
                    type: model.type,
                    typeDescriptor: model.typeDescriptor,
                    defaultExpression: model.defaultExpression,
                    defaultIsSelfContainedLiteral: model.defaultIsSelfContainedLiteral
                )
            }
            let callable = ConstExprCallableModel(
                parameters: parameters,
                resultType: originalCallable.resultType,
                resultTypeDescriptor: originalCallable.resultTypeDescriptor,
                isThrowing: false
            )
            guard !rejectUnsupportedDefaultAdapter(
                callable,
                description: "subscript",
                at: subscriptDecl,
                in: context
            ) else { return nil }
            let names = ConstExprAdapterNames(
                parameterCount: parameters.count,
                context: context
            )
            guard let invocationBody = ConstExprSyntaxSupport.memberDefaultInvocationBody(
                callable: callable,
                names: names,
                invocation: { included in
                let arguments = ConstExprSyntaxSupport.labeledCallArguments(
                    for: parameters,
                    names: names,
                    including: included
                )
                return "\(names.instance)[\(arguments)]"
            }) else { return nil }
            return registrationSource(
                name: "subscript",
                kind: ".subscriptGetter",
                owner: owner,
                attributes: subscriptDecl.attributes,
                callable: callable,
                names: names,
                invocationBody: invocationBody,
                requiresReceiver: true
            )
        }
    }

    static func isIdentifier(_ token: TokenSyntax) -> Bool {
        if case .identifier = token.tokenKind {
            return true
        }
        return false
    }

    static func registrationSource(
        name: String,
        kind: String,
        owner: String,
        attributes: AttributeListSyntax,
        callable: ConstExprCallableModel,
        names: ConstExprAdapterNames,
        invocationBody: String,
        requiresReceiver: Bool
    ) -> String {
        let receiverDecode = requiresReceiver
            ? """
              guard let \(names.receiver) else {
                  throw _ConstExprRuntime.ValueError.malformedCollection("missing \(owner) receiver")
              }
              let \(names.instance) = try \(names.receiver).require(\(ConstExprSyntaxSupport.metatypeSource(for: owner)))
              """
            : ""
        let setupBody = [receiverDecode, invocationBody]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        let setup = ConstExprSyntaxSupport.indent(setupBody, by: 8)
        let throwingArgument = callable.isThrowing
            ? "\n    isThrowing: true,"
            : ""
        let metadataArguments = ConstExprRegistrationMetadataSource(
            attributes: attributes
        ).arguments
        return """
        _ConstExprRuntime.Registration(
            moduleName: String(#fileID.split(separator: "/", maxSplits: 1).first!),
            name: \(name.constExprStringLiteral),
            kind: \(kind),
            ownerType: \(ConstExprSyntaxSupport.metatypeSource(for: owner)),
            parameterLabels: \(ConstExprSyntaxSupport.labelsSource(for: callable.parameters)),
            parameterTypes: \(ConstExprSyntaxSupport.typesSource(for: callable.parameters)),
            parameterTypeDescriptors: \(ConstExprSyntaxSupport.typeDescriptorsSource(for: callable.parameters)),
            defaultedParameters: \(ConstExprSyntaxSupport.defaultedIndicesSource(for: callable.parameters)),
            resultType: \(ConstExprSyntaxSupport.metatypeSource(for: callable.resultType)),
            resultTypeDescriptor: \(callable.resultTypeDescriptor),\(throwingArgument)\(metadataArguments)
            invoke: { \(names.receiver), \(names.arguments) in
        \(setup)
            }
        )
        """
    }
}
