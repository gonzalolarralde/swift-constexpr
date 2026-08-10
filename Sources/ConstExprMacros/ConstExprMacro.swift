import Foundation
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

public struct ConstExprMacro: PeerMacro {
    public static func expansion(
        of attribute: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        let registrationAccess = ConstExprRegistrationAccessOption(
            attribute: attribute,
            in: context
        )
        if let function = declaration.as(FunctionDeclSyntax.self) {
            if let memberContext = ConstExprDirectMemberContext(
                lexicalContext: context.lexicalContext,
                declaration: declaration
            ) {
                return expandDirectMember(
                    function: function,
                    memberContext: memberContext,
                    registrationAccess: registrationAccess,
                    attribute: attribute,
                    in: context
                )
            }
            guard !isUnsupportedCallableContext(in: context) else {
                ConstExprMacroDiagnostic.error(
                    "@ConstExpr functions must be declared at file scope; annotate an enclosing nominal type instead",
                    id: "member-annotation",
                    at: attribute,
                    in: context
                )
                return []
            }
            guard rejectGlobalActor(function.attributes, at: attribute, in: context) == false else {
                return []
            }
            return expand(
                function: function,
                registrationAccess: registrationAccess,
                attribute: attribute,
                in: context
            )
        }
        if let variable = declaration.as(VariableDeclSyntax.self) {
            if let memberContext = ConstExprDirectMemberContext(
                lexicalContext: context.lexicalContext,
                declaration: declaration
            ) {
                return expandDirectMember(
                    variable: variable,
                    memberContext: memberContext,
                    registrationAccess: registrationAccess,
                    attribute: attribute,
                    in: context
                )
            }
            guard !isUnsupportedCallableContext(in: context) else {
                ConstExprMacroDiagnostic.error(
                    "@ConstExpr variable registration is limited to file-scope constants",
                    id: "local-variable",
                    at: attribute,
                    in: context
                )
                return []
            }
            guard rejectGlobalActor(variable.attributes, at: attribute, in: context) == false else {
                return []
            }
            return expand(
                variable: variable,
                registrationAccess: registrationAccess,
                attribute: attribute,
                in: context
            )
        }
        if let initializer = declaration.as(InitializerDeclSyntax.self),
           let memberContext = ConstExprDirectMemberContext(
               lexicalContext: context.lexicalContext,
               declaration: declaration
           )
        {
            return expandDirectMember(
                initializer: initializer,
                memberContext: memberContext,
                registrationAccess: registrationAccess,
                attribute: attribute,
                in: context
            )
        }
        if let subscriptDecl = declaration.as(SubscriptDeclSyntax.self),
           let memberContext = ConstExprDirectMemberContext(
               lexicalContext: context.lexicalContext,
               declaration: declaration
           )
        {
            return expandDirectMember(
                subscriptDecl: subscriptDecl,
                memberContext: memberContext,
                registrationAccess: registrationAccess,
                attribute: attribute,
                in: context
            )
        }
        if let structure = declaration.as(StructDeclSyntax.self) {
            guard validateNominalContext(attribute: attribute, in: context),
                  rejectGlobalActor(structure.attributes, at: attribute, in: context) == false
            else { return [] }
            return ConstExprMacroDiagnostic.suppressing {
                expand(
                    nominalName: structure.name.constExprIdentifier,
                    nominalReference: structure.name.constExprIdentifierReference,
                    attributes: structure.attributes,
                    modifiers: structure.modifiers,
                    inheritanceClause: structure.inheritanceClause,
                    members: structure.memberBlock.members,
                    isGeneric: structure.genericParameterClause != nil || structure.genericWhereClause != nil,
                    requiresFinalInstanceMembers: false,
                    allowsCopiedDeprecatedStoredInitializers: true,
                    registrationAccess: registrationAccess,
                    attribute: attribute,
                    in: context
                )
            }
        }
        if let classDecl = declaration.as(ClassDeclSyntax.self) {
            guard validateNominalContext(attribute: attribute, in: context),
                  rejectGlobalActor(classDecl.attributes, at: attribute, in: context) == false
            else { return [] }
            return ConstExprMacroDiagnostic.suppressing {
                expand(
                    nominalName: classDecl.name.constExprIdentifier,
                    nominalReference: classDecl.name.constExprIdentifierReference,
                    attributes: classDecl.attributes,
                    modifiers: classDecl.modifiers,
                    inheritanceClause: classDecl.inheritanceClause,
                    members: classDecl.memberBlock.members,
                    isGeneric: classDecl.genericParameterClause != nil || classDecl.genericWhereClause != nil,
                    requiresFinalInstanceMembers: !classDecl.modifiers.constExprContains(.final),
                    allowsCopiedDeprecatedStoredInitializers: false,
                    registrationAccess: registrationAccess,
                    attribute: attribute,
                    in: context
                )
            }
        }
        if let enumDecl = declaration.as(EnumDeclSyntax.self) {
            guard validateNominalContext(attribute: attribute, in: context),
                  rejectGlobalActor(enumDecl.attributes, at: attribute, in: context) == false
            else { return [] }
            return ConstExprMacroDiagnostic.suppressing {
                expand(
                    nominalName: enumDecl.name.constExprIdentifier,
                    nominalReference: enumDecl.name.constExprIdentifierReference,
                    attributes: enumDecl.attributes,
                    modifiers: enumDecl.modifiers,
                    inheritanceClause: enumDecl.inheritanceClause,
                    members: enumDecl.memberBlock.members,
                    isGeneric: enumDecl.genericParameterClause != nil || enumDecl.genericWhereClause != nil,
                    requiresFinalInstanceMembers: false,
                    allowsCopiedDeprecatedStoredInitializers: true,
                    registrationAccess: registrationAccess,
                    attribute: attribute,
                    in: context
                )
            }
        }

        ConstExprMacroDiagnostic.error(
            "@ConstExpr can only be attached to a function, initializer, property, read-only subscript, single global let, struct, class, or enum",
            id: "invalid-attachment",
            at: attribute,
            in: context
        )
        return []
    }

    private static func expand(
        function: FunctionDeclSyntax,
        registrationAccess: ConstExprRegistrationAccessOption,
        attribute: AttributeSyntax,
        in context: some MacroExpansionContext
    ) -> [DeclSyntax] {
        guard isIdentifier(function.name) else {
            ConstExprMacroDiagnostic.error(
                "custom operators must be registered with ConstExprRegistration operator factories",
                id: "operator-function",
                at: attribute,
                in: context
            )
            return []
        }
        switch ConstExprSyntaxSupport.callableModel(
            parameters: function.signature.parameterClause.parameters,
            effectSpecifiers: function.signature.effectSpecifiers,
            returnType: function.signature.returnClause?.type,
            genericParameterClause: function.genericParameterClause,
            genericWhereClause: function.genericWhereClause
        ) {
        case .failure(let error):
            ConstExprMacroDiagnostic.error(
                error.message,
                id: "unsupported-function",
                at: attribute,
                in: context
            )
            return []
        case .success(let callable):
            let name = function.name.constExprIdentifier
            let helperName = ConstExprSyntaxSupport.synthesizedName(
                for: function.name,
                suffix: "__constExpr"
            )
            let selector = ConstExprSyntaxSupport.selectorLabel(
                for: function.signature.parameterClause.parameters
            )
            let access = registrationAccess.accessPrefix(
                declarationModifiers: function.modifiers
            )
            let names = ConstExprAdapterNames(
                parameterCount: callable.parameters.count,
                context: context
            )
            let decode = ConstExprSyntaxSupport.indent(
                ConstExprSyntaxSupport.copiedDefaultDecodeStatements(
                    for: callable.parameters,
                    names: names
                )
                    .joined(separator: "\n"),
                by: 16
            )
            let arguments = ConstExprSyntaxSupport.labeledCallArguments(
                for: callable.parameters,
                names: names
            )
            let invocation = "\(callable.isThrowing ? "try " : "")\(function.name.constExprIdentifierReference)(\(arguments)) as \(callable.resultType)"
            let throwingArgument = callable.isThrowing
                ? "\n            isThrowing: true,"
                : ""
            let metadataArguments = ConstExprRegistrationMetadataSource(
                attributes: function.attributes
            ).arguments
            let preservedAttributes = function.attributes.constExprPreservedPeerAttributes
            let attributePrefix = preservedAttributes.isEmpty ? "" : "\(preservedAttributes)\n"
            let source = """
            \(attributePrefix)\(access)func \(helperName)(
                \(selector) \(names.implementation): @escaping \(ConstExprSyntaxSupport.functionType(for: callable))
            ) -> \(registrationAccess.registrationArrayType) {
                [
                    _ConstExprRuntime.Registration(
                        moduleName: String(#fileID.split(separator: "/", maxSplits: 1).first!),
                        name: \(name.constExprStringLiteral),
                        kind: .function,
                        ownerType: nil,
                        parameterLabels: \(ConstExprSyntaxSupport.labelsSource(for: callable.parameters)),
                        parameterTypes: \(ConstExprSyntaxSupport.typesSource(for: callable.parameters)),
                        parameterTypeDescriptors: \(ConstExprSyntaxSupport.typeDescriptorsSource(for: callable.parameters)),
                        defaultedParameters: \(ConstExprSyntaxSupport.defaultedIndicesSource(for: callable.parameters)),
                        resultType: \(ConstExprSyntaxSupport.metatypeSource(for: callable.resultType)),
                        resultTypeDescriptor: \(callable.resultTypeDescriptor),\(throwingArgument)\(metadataArguments)
                        invoke: { _, \(names.arguments) in
            \(decode)
                            return _ConstExprRuntime.Value(
                                (\(invocation)) as Any,
                                preservingStaticType: \(ConstExprSyntaxSupport.metatypeSource(for: callable.resultType)),
                                sourceTypeName: \(ConstExprSyntaxSupport.sourceTypeNameSource(for: callable.resultType)),
                                isStaticallyAnyObject: \(ConstExprSyntaxSupport.staticallyAnyObjectSource(for: callable.resultType))
                            )
                        }
                    )
                ]
            }
            """
            return [DeclSyntax(stringLiteral: source)]
        }
    }

    private static func expand(
        variable: VariableDeclSyntax,
        registrationAccess: ConstExprRegistrationAccessOption,
        attribute: AttributeSyntax,
        in context: some MacroExpansionContext
    ) -> [DeclSyntax] {
        guard variable.bindingSpecifier.tokenKind == .keyword(.let) else {
            ConstExprMacroDiagnostic.error(
                "@ConstExpr can only register immutable global let bindings",
                id: "mutable-global",
                at: attribute,
                in: context
            )
            return []
        }
        guard variable.bindings.count == 1,
              let binding = variable.bindings.first,
              let pattern = binding.pattern.as(IdentifierPatternSyntax.self)
        else {
            ConstExprMacroDiagnostic.error(
                "@ConstExpr requires exactly one simple identifier binding",
                id: "multiple-bindings",
                at: attribute,
                in: context
            )
            return []
        }

        let name = pattern.identifier.constExprIdentifier
        let nameReference = pattern.identifier.constExprIdentifierReference
        let helperName = ConstExprSyntaxSupport.synthesizedName(
            for: pattern.identifier,
            suffix: "__constExpr"
        )
        let selector = ConstExprSyntaxSupport.selectorLabel(for: [String]())
        let access = registrationAccess.accessPrefix(
            declarationModifiers: variable.modifiers
        )
        let sourceTypeName: String?
        let annotatedResultTypeDescriptor: String?
        if let annotatedType = binding.typeAnnotation?.type {
            switch ConstExprSyntaxSupport.validatedValueType(annotatedType) {
            case .success(let type):
                sourceTypeName = type
                annotatedResultTypeDescriptor = ConstExprSyntaxSupport.typeDescriptorSource(
                    for: annotatedType
                )
            case .failure(let error):
                ConstExprMacroDiagnostic.error(
                    "global constant '\(name)' was not registered: \(error.message)",
                    id: "unsupported-global",
                    at: attribute,
                    in: context
                )
                return []
            }
        } else {
            sourceTypeName = nil
            annotatedResultTypeDescriptor = nil
        }
        let valueType = context.makeUniqueName("ConstExprValueType").constExprSourceSafeGeneratedIdentifier
        let resultTypeDescriptor = annotatedResultTypeDescriptor
            ?? "_ConstExprRuntime.StaticTypeDescriptor.inferred(\(valueType).self)"
        let value = context.makeUniqueName("constExprValue").constExprSourceSafeGeneratedIdentifier
        let preservedAttributes = variable.attributes.constExprPreservedPeerAttributes
        let attributePrefix = preservedAttributes.isEmpty ? "" : "\(preservedAttributes)\n"
        let metadataArguments = ConstExprRegistrationMetadataSource(
            attributes: variable.attributes
        ).arguments
        let source = """
        \(attributePrefix)\(access)func \(helperName)<\(valueType)>(
            \(selector) \(value): @autoclosure @escaping () -> \(valueType)
        ) -> \(registrationAccess.registrationArrayType) {
            [
                _ConstExprRuntime.Registration(
                    moduleName: String(#fileID.split(separator: "/", maxSplits: 1).first!),
                    name: \(name.constExprStringLiteral),
                    kind: .constant,
                    ownerType: nil,
                    parameterLabels: [],
                    parameterTypes: [],
                    parameterTypeDescriptors: [],
                    defaultedParameters: [],
                    resultType: \(valueType).self,
                    resultTypeDescriptor: \(resultTypeDescriptor),\(metadataArguments)
                    invoke: { _, _ in
                        _ConstExprRuntime.Value(
                            (\(nameReference)) as Any,
                            preservingStaticType: \(valueType).self,
                            sourceTypeName: \(ConstExprSyntaxSupport.sourceTypeNameSource(for: sourceTypeName))
                        )
                    }
                )
            ]
        }
        """
        return [DeclSyntax(stringLiteral: source)]
    }

}
