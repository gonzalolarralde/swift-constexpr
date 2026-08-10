import Foundation
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

extension ConstExprMacro {
    static func propertyRegistrations(
        _ variable: VariableDeclSyntax,
        owner: String,
        nominalContext: ConstExprNominalContext,
        providerAccess: ConstExprAccessLevel,
        requiresFinalInstanceMembers: Bool,
        allowsAvailability: Bool = false,
        allowsCopiedDeprecatedStoredInitializer: Bool = false,
        in context: some MacroExpansionContext
    ) -> [String] {
        if rejectUnsafeMemberAttributes(
            variable.attributes,
            description: "property",
            allowsAvailability: allowsAvailability,
            at: variable,
            in: context
        ) {
            return []
        }
        if variable.modifiers.constExprAccessLevel == .private {
            return []
        }
        if hasInsufficientAccess(
            variable.modifiers,
            providerAccess: providerAccess
        ) {
            return []
        }
        if variable.modifiers.constExprContains(.dynamic) {
            ConstExprMacroDiagnostic.warning(
                "dynamic property was not registered because runtime replacement or dispatch can invoke an unregistered implementation",
                id: "dynamic-member",
                at: variable,
                in: context
            )
            return []
        }
        if variable.modifiers.constExprContains(.lazy) {
            ConstExprMacroDiagnostic.warning(
                "lazy property was not registered because reading it may mutate the receiver",
                id: "lazy-property",
                at: variable,
                in: context
            )
            return []
        }
        let isStatic = variable.modifiers.constExprContains(.static)
            || variable.modifiers.constExprContains(.class)
        let copiesDeprecatedInitializer = ConstExprRegistrationMetadataSource(
            attributes: variable.attributes
        ).hasDeprecatedAvailability
        if copiesDeprecatedInitializer && !allowsCopiedDeprecatedStoredInitializer {
            return []
        }
        if requiresFinalInstanceMembers,
           !isStatic,
           !variable.modifiers.constExprContains(.final)
        {
            ConstExprMacroDiagnostic.warning(
                "overridable instance property was not registered; mark the class or property final to prevent dispatch to an unregistered override",
                id: "overridable-member",
                at: variable,
                in: context
            )
            return []
        }

        return variable.bindings.compactMap { binding in
            let copiedInitializer: ExprSyntax?
            if copiesDeprecatedInitializer {
                guard isStatic,
                      variable.bindingSpecifier.tokenKind == .keyword(.let),
                      binding.accessorBlock == nil,
                      let initializer = binding.initializer?.value,
                      ConstExprSyntaxSupport
                        .isRecursivelySelfContainedConstantInitializer(initializer)
                else { return nil }
                copiedInitializer = initializer
            } else {
                copiedInitializer = nil
            }
            if let accessors = binding.accessorBlock?.accessors.as(AccessorDeclListSyntax.self),
               accessors.contains(where: { $0.effectSpecifiers != nil })
            {
                ConstExprMacroDiagnostic.warning(
                    "async or throwing property accessor was not registered",
                    id: "effectful-property",
                    at: binding,
                    in: context
                )
                return nil
            }
            if let accessors = binding.accessorBlock?.accessors.as(AccessorDeclListSyntax.self),
               accessors.contains(where: { accessor in
                   guard ["get", "_read", "read"].contains(accessor.accessorSpecifier.text) else {
                       return false
                   }
                   return ConstExprSyntaxSupport
                       .hasMutatingOrConsumingModifier(accessor)
               })
            {
                ConstExprMacroDiagnostic.warning(
                    "mutating or consuming property getter was not registered",
                    id: "mutating-getter",
                    at: binding,
                    in: context
                )
                return nil
            }
            guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else {
                ConstExprMacroDiagnostic.warning(
                    "property with a non-identifier pattern was not registered",
                    id: "unsupported-property",
                    at: binding,
                    in: context
                )
                return nil
            }
            guard let typeSyntax = binding.typeAnnotation?.type else {
                ConstExprMacroDiagnostic.warning(
                    "property '\(pattern.identifier.constExprIdentifier)' needs an explicit type to be registered",
                    id: "inferred-property",
                    at: binding,
                    in: context
                )
                return nil
            }
            let type: String
            switch ConstExprSyntaxSupport.validatedValueType(
                typeSyntax,
                nominalContext: nominalContext
            ) {
            case .success(let valueType):
                type = valueType
            case .failure(let error):
                ConstExprMacroDiagnostic.warning(
                    "property '\(pattern.identifier.constExprIdentifier)' was not registered: \(error.message)",
                    id: "unsupported-property",
                    at: binding,
                    in: context
                )
                return nil
            }
            let name = pattern.identifier.constExprIdentifier
            let nameReference = pattern.identifier.constExprIdentifierReference
            let callable = ConstExprCallableModel(
                parameters: [],
                resultType: type,
                resultTypeDescriptor: ConstExprSyntaxSupport.typeDescriptorSource(
                    for: typeSyntax,
                    nominalContext: nominalContext
                ),
                isThrowing: false
            )
            let names = ConstExprAdapterNames(parameterCount: 0, context: context)
            let invocationBody: String
            if let copiedInitializer {
                invocationBody = """
                let \(names.instance): \(type) = (\(copiedInitializer.constExprSource))
                return _ConstExprRuntime.Value((\(names.instance)) as Any, preservingStaticType: \(ConstExprSyntaxSupport.metatypeSource(for: type)), sourceTypeName: \(ConstExprSyntaxSupport.sourceTypeNameSource(for: type)), isStaticallyAnyObject: \(ConstExprSyntaxSupport.staticallyAnyObjectSource(for: type)))
                """
            } else {
                invocationBody = "return _ConstExprRuntime.Value((\(isStatic ? owner : names.instance).\(nameReference)) as Any, preservingStaticType: \(ConstExprSyntaxSupport.metatypeSource(for: type)), sourceTypeName: \(ConstExprSyntaxSupport.sourceTypeNameSource(for: type)), isStaticallyAnyObject: \(ConstExprSyntaxSupport.staticallyAnyObjectSource(for: type)))"
            }
            return registrationSource(
                name: name,
                kind: isStatic ? ".staticProperty" : ".instanceProperty",
                owner: owner,
                attributes: variable.attributes,
                callable: callable,
                names: names,
                invocationBody: invocationBody,
                requiresReceiver: !isStatic
            )
        }
    }

    static func enumCaseRegistrations(
        _ enumCase: EnumCaseDeclSyntax,
        owner: String,
        nominalContext: ConstExprNominalContext,
        allowsAvailability: Bool = false,
        in context: some MacroExpansionContext
    ) -> [String] {
        if rejectUnsafeMemberAttributes(
            enumCase.attributes,
            description: "enum case",
            allowsAvailability: allowsAvailability,
            at: enumCase,
            in: context
        ) {
            return []
        }
        return enumCase.elements.compactMap { element -> String? in
            if let clause = element.parameterClause {
                var parameters: [ConstExprParameterModel] = []
                for parameter in clause.parameters {
                    let type: String
                    switch ConstExprSyntaxSupport.validatedValueType(
                        parameter.type,
                        nominalContext: nominalContext
                    ) {
                    case .success(let valueType):
                        type = valueType
                    case .failure(let error):
                        ConstExprMacroDiagnostic.warning(
                            "associated-value enum case '\(element.name.constExprIdentifier)' was not registered: \(error.message)",
                            id: "unsupported-associated-value",
                            at: parameter,
                            in: context
                        )
                        return nil
                    }
                    let defaultExpression = parameter.defaultValue?.value.constExprSource
                    if let defaultValue = parameter.defaultValue?.value,
                       ConstExprSyntaxSupport.containsCallerLocation(defaultValue)
                    {
                        ConstExprMacroDiagnostic.warning(
                            "associated-value enum case '\(element.name.constExprIdentifier)' was not registered: caller-location default arguments are unsupported",
                            id: "unsupported-associated-value",
                            at: parameter,
                            in: context
                        )
                        return nil
                    }
                    let firstName = parameter.firstName?.constExprIdentifier
                    parameters.append(
                        ConstExprParameterModel(
                            label: firstName == nil || firstName == "_" ? nil : firstName,
                            invocationLabel: firstName == nil || firstName == "_"
                                ? nil
                                : parameter.firstName?.constExprIdentifier,
                            type: type,
                            typeDescriptor: ConstExprSyntaxSupport.typeDescriptorSource(
                                for: parameter.type,
                                nominalContext: nominalContext
                            ),
                            defaultExpression: defaultExpression,
                            defaultIsSelfContainedLiteral: parameter.defaultValue.map {
                                ConstExprSyntaxSupport.isSelfContainedDefaultLiteral($0.value)
                            } ?? false
                        )
                    )
                }
                let callable = ConstExprCallableModel(
                    parameters: parameters,
                    resultType: owner,
                    resultTypeDescriptor: ConstExprSyntaxSupport.typeDescriptorSource(
                        for: TypeSyntax(stringLiteral: owner),
                        nominalContext: nominalContext
                    ),
                    isThrowing: false
                )
                guard !rejectUnsupportedDefaultAdapter(
                    callable,
                    description: "associated-value enum case '\(element.name.constExprIdentifier)'",
                    at: element,
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
                    return "\(owner).\(element.name.constExprIdentifierReference)(\(arguments))"
                }) else { return nil }
                return registrationSource(
                    name: element.name.constExprIdentifier,
                    kind: ".staticMethod",
                    owner: owner,
                    attributes: enumCase.attributes,
                    callable: callable,
                    names: names,
                    invocationBody: invocationBody,
                    requiresReceiver: false
                )
            }
            let callable = ConstExprCallableModel(
                parameters: [],
                resultType: owner,
                resultTypeDescriptor: ConstExprSyntaxSupport.typeDescriptorSource(
                    for: TypeSyntax(stringLiteral: owner),
                    nominalContext: nominalContext
                ),
                isThrowing: false
            )
            let names = ConstExprAdapterNames(parameterCount: 0, context: context)
            return registrationSource(
                name: element.name.constExprIdentifier,
                kind: ".staticProperty",
                owner: owner,
                attributes: enumCase.attributes,
                callable: callable,
                names: names,
                invocationBody: "return _ConstExprRuntime.Value((\(owner).\(element.name.constExprIdentifierReference)) as Any, preservingStaticType: \(ConstExprSyntaxSupport.metatypeSource(for: owner)), sourceTypeName: \(ConstExprSyntaxSupport.sourceTypeNameSource(for: owner)), isStaticallyAnyObject: \(ConstExprSyntaxSupport.staticallyAnyObjectSource(for: owner)))",
                requiresReceiver: false
            )
        }
    }

}
