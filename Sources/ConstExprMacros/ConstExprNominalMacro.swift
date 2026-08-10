import Foundation
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

extension ConstExprMacro {
    static func expand(
        nominalName: String,
        nominalReference: String,
        attributes: AttributeListSyntax,
        modifiers: DeclModifierListSyntax,
        inheritanceClause: InheritanceClauseSyntax?,
        members: MemberBlockItemListSyntax,
        isGeneric: Bool,
        requiresFinalInstanceMembers: Bool,
        allowsCopiedDeprecatedStoredInitializers: Bool,
        registrationAccess requestedRegistrationAccess: ConstExprRegistrationAccessOption,
        attribute: AttributeSyntax,
        in context: some MacroExpansionContext
    ) -> [DeclSyntax] {
        guard !isGeneric else {
            ConstExprMacroDiagnostic.error(
                "generic nominal types are not supported by @ConstExpr",
                id: "generic-type",
                at: attribute,
                in: context
            )
            return []
        }
        let localTypeNames = Set(members.compactMap { item -> String? in
            if let decl = item.decl.as(StructDeclSyntax.self) {
                return decl.name.constExprIdentifier
            }
            if let decl = item.decl.as(ClassDeclSyntax.self) {
                return decl.name.constExprIdentifier
            }
            if let decl = item.decl.as(EnumDeclSyntax.self) {
                return decl.name.constExprIdentifier
            }
            if let decl = item.decl.as(ActorDeclSyntax.self) {
                return decl.name.constExprIdentifier
            }
            if let decl = item.decl.as(ProtocolDeclSyntax.self) {
                return decl.name.constExprIdentifier
            }
            if let decl = item.decl.as(TypeAliasDeclSyntax.self) {
                return decl.name.constExprIdentifier
            }
            return nil
        })
        let nominalContext = ConstExprNominalContext(
            ownerReference: nominalReference,
            localTypeNames: localTypeNames
        )
        let providerAccess = modifiers.constExprAccessLevel
        var registrations: [String] = []
        var arrayLiteralRegistrations: String?

        let hasDirectArrayLiteralConformance = directlyInheritsArrayLiteralProtocol(
            inheritanceClause
        )
        if hasDirectArrayLiteralConformance {
            arrayLiteralRegistrations = arrayLiteralRegistration(
               members: members,
               owner: nominalReference,
               nominalContext: nominalContext,
               providerAccess: providerAccess,
               attribute: attribute,
               in: context
           )
        }

        for item in members {
            if let initializer = item.decl.as(InitializerDeclSyntax.self) {
                if shouldSkipWholeNominalMember(initializer.attributes) { continue }
                // Array-literal witnesses have variadic source semantics and
                // therefore use their dedicated registration path. Do not
                // also feed them to the fixed-arity callable adapter, whose
                // generic variadic diagnostic would be both noisy and wrong.
                if hasDirectArrayLiteralConformance,
                   isArrayLiteralInitializer(initializer)
                {
                    continue
                }
                if let registration = initializerRegistration(
                    initializer,
                    owner: nominalReference,
                    nominalContext: nominalContext,
                    providerAccess: providerAccess,
                    allowsAvailability: true,
                    in: context
                ) {
                    registrations.append(registration)
                }
                continue
            }
            if let function = item.decl.as(FunctionDeclSyntax.self) {
                if shouldSkipWholeNominalMember(function.attributes) { continue }
                if let registration = methodRegistration(
                    function,
                    owner: nominalReference,
                    nominalContext: nominalContext,
                    providerAccess: providerAccess,
                    requiresFinalInstanceMembers: requiresFinalInstanceMembers,
                    allowsAvailability: true,
                    in: context
                ) {
                    registrations.append(registration)
                }
                continue
            }
            if let variable = item.decl.as(VariableDeclSyntax.self) {
                let metadata = ConstExprRegistrationMetadataSource(
                    attributes: variable.attributes
                )
                if metadata.isUnconditionallyUnavailable
                    || metadata.hasObsoletedAvailability
                {
                    continue
                }
                registrations.append(
                    contentsOf: propertyRegistrations(
                        variable,
                        owner: nominalReference,
                        nominalContext: nominalContext,
                        providerAccess: providerAccess,
                        requiresFinalInstanceMembers: requiresFinalInstanceMembers,
                        allowsAvailability: true,
                        allowsCopiedDeprecatedStoredInitializer: allowsCopiedDeprecatedStoredInitializers,
                        in: context
                    )
                )
                continue
            }
            if let enumCase = item.decl.as(EnumCaseDeclSyntax.self) {
                if shouldSkipWholeNominalMember(enumCase.attributes) { continue }
                registrations.append(
                    contentsOf: enumCaseRegistrations(
                        enumCase,
                        owner: nominalReference,
                        nominalContext: nominalContext,
                        allowsAvailability: true,
                        in: context
                    )
                )
                continue
            }
            if let subscriptDecl = item.decl.as(SubscriptDeclSyntax.self) {
                if shouldSkipWholeNominalMember(subscriptDecl.attributes) { continue }
                if let registration = subscriptRegistration(
                    subscriptDecl,
                    owner: nominalReference,
                    nominalContext: nominalContext,
                    providerAccess: providerAccess,
                    requiresFinalInstanceMembers: requiresFinalInstanceMembers,
                    allowsAvailability: true,
                    in: context
                ) {
                    registrations.append(registration)
                }
            }
        }

        let access = requestedRegistrationAccess.accessPrefix(
            declarationModifiers: modifiers
        )
        let registrationAccess: String
        switch requestedRegistrationAccess.accessLevel(
            declarationModifiers: modifiers
        ) {
        case .public:
            registrationAccess = "public "
        case .package:
            registrationAccess = "package "
        case .private, .fileprivate, .internal:
            // A member need not repeat its enclosing provider's restriction.
            // In particular, `private static` would make the registry array
            // inaccessible even to a same-file #constExprRegistry expansion.
            registrationAccess = ""
        }
        let preservedAttributes = attributes.constExprPreservedPeerAttributes
        let attributePrefix = preservedAttributes.isEmpty ? "" : "\(preservedAttributes)\n"
        if registrations.count > ConstExprRegistrationChunkSyntax.limit {
            let erasedArrayLiteral = arrayLiteralRegistrations.map {
                requestedRegistrationAccess.erasedRegistrationPrefix($0)
            }
            let members = ConstExprRegistrationChunkSyntax.nominalProviderMembers(
                registrations: registrations,
                arrayLiteralRegistrations: erasedArrayLiteral,
                arrayType: requestedRegistrationAccess.registrationArrayType,
                registrationAccess: registrationAccess
            )
            let source = """
            \(attributePrefix)\(access)enum \(nominalName)__constExpr {
            \(ConstExprSyntaxSupport.indent(members, by: 4))
            }
            """
            return [DeclSyntax(stringLiteral: source)]
        }
        let entries = registrations.map { registration in
            registration.split(separator: "\n", omittingEmptySubsequences: false)
                .map { "            \($0)" }
                .joined(separator: "\n")
        }.joined(separator: ",\n")
        let arrayLiteralPrefix = arrayLiteralRegistrations.map { registrations in
            let registrations = requestedRegistrationAccess.erasedRegistrationPrefix(
                registrations
            )
            return registrations.split(separator: "\n", omittingEmptySubsequences: false)
                .map { "        \($0)" }
                .joined(separator: "\n") + " + "
        } ?? ""
        let listIndent = arrayLiteralRegistrations == nil ? "        " : ""
        let source = """
        \(attributePrefix)\(access)enum \(nominalName)__constExpr {
            \(registrationAccess)static var registrations: \(requestedRegistrationAccess.registrationArrayType) {
        \(arrayLiteralPrefix)\(listIndent)[
        \(entries)
                ]
            }
        }
        """
        return [DeclSyntax(stringLiteral: source)]
    }

    private static func shouldSkipWholeNominalMember(
        _ attributes: AttributeListSyntax
    ) -> Bool {
        let metadata = ConstExprRegistrationMetadataSource(attributes: attributes)
        // Invoking an unconditionally unavailable declaration is a hard error,
        // while spelling a deprecated declaration can make a Werror build fail.
        // Both remain original-source compiler work.
        return metadata.isUnconditionallyUnavailable
            || metadata.hasDeprecatedAvailability
            || metadata.hasObsoletedAvailability
    }

    private struct ArrayLiteralWitnessModel {
        let elementType: String
        let elementTypeDescriptor: String
    }

    /// A syntax macro cannot discover conformances introduced by another
    /// declaration. Requiring the protocol name in the annotated nominal's
    /// own inheritance clause keeps array-literal execution inside the same
    /// explicit trust boundary as ordinary generated member adapters.
    private static func directlyInheritsArrayLiteralProtocol(
        _ inheritanceClause: InheritanceClauseSyntax?
    ) -> Bool {
        inheritanceClause?.inheritedTypes.contains { inherited in
            let source = inherited.type.constExprSource
                .replacingOccurrences(of: " ", with: "")
            return source == "ExpressibleByArrayLiteral"
                || source == "Swift.ExpressibleByArrayLiteral"
        } == true
    }

    private static func isArrayLiteralInitializer(
        _ initializer: InitializerDeclSyntax
    ) -> Bool {
        initializer.signature.parameterClause.parameters.first?
            .firstName.constExprIdentifier == "arrayLiteral"
    }

    private static func arrayLiteralRegistration(
        members: MemberBlockItemListSyntax,
        owner: String,
        nominalContext: ConstExprNominalContext,
        providerAccess: ConstExprAccessLevel,
        attribute: AttributeSyntax,
        in context: some MacroExpansionContext
    ) -> String? {
        let candidates = members.compactMap { item in
            item.decl.as(InitializerDeclSyntax.self)
        }.filter(isArrayLiteralInitializer)

        guard !candidates.isEmpty else {
            ConstExprMacroDiagnostic.warning(
                "ExpressibleByArrayLiteral conformance was not registered because its init(arrayLiteral:) witness is not visible in the annotated primary declaration",
                id: "array-literal-witness-not-visible",
                at: attribute,
                in: context
            )
            return nil
        }

        let eligible = candidates.compactMap { initializer in
            arrayLiteralWitnessModel(
                initializer,
                nominalContext: nominalContext,
                providerAccess: providerAccess,
                in: context
            )
        }
        guard eligible.count == 1, let witness = eligible.first else {
            if eligible.count > 1 {
                ConstExprMacroDiagnostic.warning(
                    "ExpressibleByArrayLiteral conformance was not registered because multiple eligible init(arrayLiteral:) witnesses are visible",
                    id: "ambiguous-array-literal-witness",
                    at: attribute,
                    in: context
                )
            }
            return nil
        }

        let resultType = TypeSyntax(stringLiteral: owner)
        let resultDescriptor = ConstExprSyntaxSupport.typeDescriptorSource(
            for: resultType
        )
        return """
        _ConstExprRuntime.arrayLiteralRegistrations(
            result: (\(owner)).self,
            element: (\(witness.elementType)).self,
            elementTypeDescriptor: \(witness.elementTypeDescriptor),
            resultTypeDescriptor: \(resultDescriptor),
            moduleName: String(#fileID.split(separator: "/", maxSplits: 1).first!)
        )
        """
    }

    private static func arrayLiteralWitnessModel(
        _ initializer: InitializerDeclSyntax,
        nominalContext: ConstExprNominalContext,
        providerAccess: ConstExprAccessLevel,
        in context: some MacroExpansionContext
    ) -> ArrayLiteralWitnessModel? {
        if rejectUnsafeMemberAttributes(
            initializer.attributes,
            description: "array-literal initializer",
            at: initializer,
            in: context
        ) {
            return nil
        }
        if initializer.modifiers.constExprAccessLevel == .private {
            ConstExprMacroDiagnostic.warning(
                "private init(arrayLiteral:) witness was not registered",
                id: "private-array-literal-witness",
                at: initializer,
                in: context
            )
            return nil
        }
        if hasInsufficientAccess(
            initializer.modifiers,
            providerAccess: providerAccess
        ) {
            ConstExprMacroDiagnostic.warning(
                "init(arrayLiteral:) witness was not registered because its access is lower than the generated provider",
                id: "inaccessible-array-literal-witness",
                at: initializer,
                in: context
            )
            return nil
        }

        let parameters = initializer.signature.parameterClause.parameters
        guard parameters.count == 1,
              let parameter = parameters.first,
              parameter.firstName.constExprIdentifier == "arrayLiteral",
              parameter.ellipsis != nil,
              parameter.defaultValue == nil,
              parameter.attributes.isEmpty,
              initializer.optionalMark == nil,
              initializer.genericParameterClause == nil,
              initializer.genericWhereClause == nil,
              initializer.signature.effectSpecifiers?.asyncSpecifier == nil,
              initializer.signature.effectSpecifiers?.throwsClause == nil
        else {
            ConstExprMacroDiagnostic.warning(
                "init(arrayLiteral:) was not registered because an array-literal witness must be a nonfailable, nonthrowing, nongeneric initializer with exactly one nondefaulted variadic parameter",
                id: "invalid-array-literal-witness",
                at: initializer,
                in: context
            )
            return nil
        }

        switch ConstExprSyntaxSupport.validatedValueType(
            parameter.type,
            nominalContext: nominalContext
        ) {
        case .failure(let error):
            ConstExprMacroDiagnostic.warning(
                "init(arrayLiteral:) was not registered: \(error.message)",
                id: "unsupported-array-literal-element",
                at: initializer,
                in: context
            )
            return nil
        case .success(let elementType):
            return ArrayLiteralWitnessModel(
                elementType: elementType,
                elementTypeDescriptor: ConstExprSyntaxSupport.typeDescriptorSource(
                    for: parameter.type,
                    nominalContext: nominalContext
                )
            )
        }
    }

}
