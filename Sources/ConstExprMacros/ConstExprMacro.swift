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
        if let function = declaration.as(FunctionDeclSyntax.self) {
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
            return expand(function: function, attribute: attribute, in: context)
        }
        if let variable = declaration.as(VariableDeclSyntax.self) {
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
            return expand(variable: variable, attribute: attribute, in: context)
        }
        if let structure = declaration.as(StructDeclSyntax.self) {
            guard validateNominalContext(attribute: attribute, in: context),
                  rejectGlobalActor(structure.attributes, at: attribute, in: context) == false
            else { return [] }
            return expand(
                nominalName: structure.name.constExprIdentifier,
                nominalReference: structure.name.constExprIdentifierReference,
                attributes: structure.attributes,
                modifiers: structure.modifiers,
                inheritanceClause: structure.inheritanceClause,
                members: structure.memberBlock.members,
                isGeneric: structure.genericParameterClause != nil || structure.genericWhereClause != nil,
                requiresFinalInstanceMembers: false,
                attribute: attribute,
                in: context
            )
        }
        if let classDecl = declaration.as(ClassDeclSyntax.self) {
            guard validateNominalContext(attribute: attribute, in: context),
                  rejectGlobalActor(classDecl.attributes, at: attribute, in: context) == false
            else { return [] }
            return expand(
                nominalName: classDecl.name.constExprIdentifier,
                nominalReference: classDecl.name.constExprIdentifierReference,
                attributes: classDecl.attributes,
                modifiers: classDecl.modifiers,
                inheritanceClause: classDecl.inheritanceClause,
                members: classDecl.memberBlock.members,
                isGeneric: classDecl.genericParameterClause != nil || classDecl.genericWhereClause != nil,
                requiresFinalInstanceMembers: !classDecl.modifiers.constExprContains(.final),
                attribute: attribute,
                in: context
            )
        }
        if let enumDecl = declaration.as(EnumDeclSyntax.self) {
            guard validateNominalContext(attribute: attribute, in: context),
                  rejectGlobalActor(enumDecl.attributes, at: attribute, in: context) == false
            else { return [] }
            return expand(
                nominalName: enumDecl.name.constExprIdentifier,
                nominalReference: enumDecl.name.constExprIdentifierReference,
                attributes: enumDecl.attributes,
                modifiers: enumDecl.modifiers,
                inheritanceClause: enumDecl.inheritanceClause,
                members: enumDecl.memberBlock.members,
                isGeneric: enumDecl.genericParameterClause != nil || enumDecl.genericWhereClause != nil,
                requiresFinalInstanceMembers: false,
                attribute: attribute,
                in: context
            )
        }

        ConstExprMacroDiagnostic.error(
            "@ConstExpr can only be attached to a function, a single global let, a struct, a class, or an enum",
            id: "invalid-attachment",
            at: attribute,
            in: context
        )
        return []
    }

    private static func isUnsupportedCallableContext(in context: some MacroExpansionContext) -> Bool {
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

    private static func validateNominalContext(
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
            if syntax.is(ExtensionDeclSyntax.self)
                || syntax.is(ProtocolDeclSyntax.self)
                || syntax.is(ActorDeclSyntax.self)
            {
                ConstExprMacroDiagnostic.error(
                    "@ConstExpr nominal types are not supported in extensions, protocols, or actors",
                    id: "unsupported-nominal-context",
                    at: attribute,
                    in: context
                )
                return false
            }
            if let structure = syntax.as(StructDeclSyntax.self),
               structure.genericParameterClause != nil || structure.genericWhereClause != nil
            {
                ConstExprMacroDiagnostic.error(
                    "@ConstExpr nominal types cannot be nested in a generic context",
                    id: "generic-context",
                    at: attribute,
                    in: context
                )
                return false
            }
            if let classDecl = syntax.as(ClassDeclSyntax.self),
               classDecl.genericParameterClause != nil || classDecl.genericWhereClause != nil
            {
                ConstExprMacroDiagnostic.error(
                    "@ConstExpr nominal types cannot be nested in a generic context",
                    id: "generic-context",
                    at: attribute,
                    in: context
                )
                return false
            }
            if let enumDecl = syntax.as(EnumDeclSyntax.self),
               enumDecl.genericParameterClause != nil || enumDecl.genericWhereClause != nil
            {
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

    private static func rejectGlobalActor(
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

    private static func expand(
        function: FunctionDeclSyntax,
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
            let access = function.modifiers.constExprAccessPrefix
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
            let preservedAttributes = function.attributes.constExprPreservedPeerAttributes
            let attributePrefix = preservedAttributes.isEmpty ? "" : "\(preservedAttributes)\n"
            let source = """
            \(attributePrefix)\(access)func \(helperName)(
                \(selector) \(names.implementation): @escaping \(ConstExprSyntaxSupport.functionType(for: callable))
            ) -> [_ConstExprRuntime.Registration] {
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
                        resultTypeDescriptor: \(callable.resultTypeDescriptor),\(throwingArgument)
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
        let access = variable.modifiers.constExprAccessPrefix
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
        let source = """
        \(attributePrefix)\(access)func \(helperName)<\(valueType)>(
            \(selector) \(value): @autoclosure @escaping () -> \(valueType)
        ) -> [_ConstExprRuntime.Registration] {
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
                    resultTypeDescriptor: \(resultTypeDescriptor),
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

    private static func expand(
        nominalName: String,
        nominalReference: String,
        attributes: AttributeListSyntax,
        modifiers: DeclModifierListSyntax,
        inheritanceClause: InheritanceClauseSyntax?,
        members: MemberBlockItemListSyntax,
        isGeneric: Bool,
        requiresFinalInstanceMembers: Bool,
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
                    in: context
                ) {
                    registrations.append(registration)
                }
                continue
            }
            if let function = item.decl.as(FunctionDeclSyntax.self) {
                if let registration = methodRegistration(
                    function,
                    owner: nominalReference,
                    nominalContext: nominalContext,
                    providerAccess: providerAccess,
                    requiresFinalInstanceMembers: requiresFinalInstanceMembers,
                    in: context
                ) {
                    registrations.append(registration)
                }
                continue
            }
            if let variable = item.decl.as(VariableDeclSyntax.self) {
                registrations.append(
                    contentsOf: propertyRegistrations(
                        variable,
                        owner: nominalReference,
                        nominalContext: nominalContext,
                        providerAccess: providerAccess,
                        requiresFinalInstanceMembers: requiresFinalInstanceMembers,
                        in: context
                    )
                )
                continue
            }
            if let enumCase = item.decl.as(EnumCaseDeclSyntax.self) {
                registrations.append(
                    contentsOf: enumCaseRegistrations(
                        enumCase,
                        owner: nominalReference,
                        nominalContext: nominalContext,
                        in: context
                    )
                )
                continue
            }
            if let subscriptDecl = item.decl.as(SubscriptDeclSyntax.self) {
                if let registration = subscriptRegistration(
                    subscriptDecl,
                    owner: nominalReference,
                    nominalContext: nominalContext,
                    providerAccess: providerAccess,
                    requiresFinalInstanceMembers: requiresFinalInstanceMembers,
                    in: context
                ) {
                    registrations.append(registration)
                }
            }
        }

        let access = modifiers.constExprAccessPrefix
        let registrationAccess: String
        switch modifiers.constExprAccessLevel {
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
        let entries = registrations.map { registration in
            registration.split(separator: "\n", omittingEmptySubsequences: false)
                .map { "            \($0)" }
                .joined(separator: "\n")
        }.joined(separator: ",\n")
        let arrayLiteralPrefix = arrayLiteralRegistrations.map { registrations in
            registrations.split(separator: "\n", omittingEmptySubsequences: false)
                .map { "        \($0)" }
                .joined(separator: "\n") + " + "
        } ?? ""
        let listIndent = arrayLiteralRegistrations == nil ? "        " : ""
        let source = """
        \(attributePrefix)\(access)enum \(nominalName)__constExpr {
            \(registrationAccess)static var registrations: [_ConstExprRuntime.Registration] {
        \(arrayLiteralPrefix)\(listIndent)[
        \(entries)
                ]
            }
        }
        """
        return [DeclSyntax(stringLiteral: source)]
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

    private static func rejectUnsafeMemberAttributes(
        _ attributes: AttributeListSyntax,
        description: String,
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
        if attributes.constExprHasAvailabilityConstraint {
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

    private static func hasInsufficientAccess(
        _ modifiers: DeclModifierListSyntax,
        providerAccess: ConstExprAccessLevel
    ) -> Bool {
        return modifiers.constExprAccessLevel < providerAccess
    }

    private static func initializerRegistration(
        _ initializer: InitializerDeclSyntax,
        owner: String,
        nominalContext: ConstExprNominalContext,
        providerAccess: ConstExprAccessLevel,
        in context: some MacroExpansionContext
    ) -> String? {
        if rejectUnsafeMemberAttributes(
            initializer.attributes,
            description: "initializer",
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
            let names = ConstExprAdapterNames(
                parameterCount: callable.parameters.count,
                context: context
            )
            let invocationBody = ConstExprSyntaxSupport.nativeDefaultInvocationBody(
                callable: callable,
                names: names
            ) { included in
                let arguments = ConstExprSyntaxSupport.labeledCallArguments(
                    for: callable.parameters,
                    names: names,
                    including: included
                )
                return "\(callable.isThrowing ? "try " : "")\(owner)(\(arguments))"
            }
            return registrationSource(
                name: owner.constExprSemanticIdentifier,
                kind: ".initializer",
                owner: owner,
                callable: callable,
                names: names,
                invocationBody: invocationBody,
                requiresReceiver: false
            )
        }
    }

    private static func methodRegistration(
        _ function: FunctionDeclSyntax,
        owner: String,
        nominalContext: ConstExprNominalContext,
        providerAccess: ConstExprAccessLevel,
        requiresFinalInstanceMembers: Bool,
        in context: some MacroExpansionContext
    ) -> String? {
        if rejectUnsafeMemberAttributes(
            function.attributes,
            description: "method '\(function.name.constExprIdentifier)'",
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
            let names = ConstExprAdapterNames(
                parameterCount: callable.parameters.count,
                context: context
            )
            let invocationBody = ConstExprSyntaxSupport.nativeDefaultInvocationBody(
                callable: callable,
                names: names
            ) { included in
                let arguments = ConstExprSyntaxSupport.labeledCallArguments(
                    for: callable.parameters,
                    names: names,
                    including: included
                )
                let base = isStatic ? owner : names.instance
                return "\(callable.isThrowing ? "try " : "")\(base).\(function.name.constExprIdentifierReference)(\(arguments))"
            }
            return registrationSource(
                name: function.name.constExprIdentifier,
                kind: isStatic ? ".staticMethod" : ".instanceMethod",
                owner: owner,
                callable: callable,
                names: names,
                invocationBody: invocationBody,
                requiresReceiver: !isStatic
            )
        }
    }

    private static func propertyRegistrations(
        _ variable: VariableDeclSyntax,
        owner: String,
        nominalContext: ConstExprNominalContext,
        providerAccess: ConstExprAccessLevel,
        requiresFinalInstanceMembers: Bool,
        in context: some MacroExpansionContext
    ) -> [String] {
        if rejectUnsafeMemberAttributes(
            variable.attributes,
            description: "property",
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
                   guard let modifier = accessor.modifier?.name.text else { return false }
                   return modifier == "mutating" || modifier == "consuming"
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
            return registrationSource(
                name: name,
                kind: isStatic ? ".staticProperty" : ".instanceProperty",
                owner: owner,
                callable: callable,
                names: names,
                invocationBody: "return _ConstExprRuntime.Value((\(isStatic ? owner : names.instance).\(nameReference)) as Any, preservingStaticType: \(ConstExprSyntaxSupport.metatypeSource(for: type)), sourceTypeName: \(ConstExprSyntaxSupport.sourceTypeNameSource(for: type)), isStaticallyAnyObject: \(ConstExprSyntaxSupport.staticallyAnyObjectSource(for: type)))",
                requiresReceiver: !isStatic
            )
        }
    }

    private static func enumCaseRegistrations(
        _ enumCase: EnumCaseDeclSyntax,
        owner: String,
        nominalContext: ConstExprNominalContext,
        in context: some MacroExpansionContext
    ) -> [String] {
        if rejectUnsafeMemberAttributes(
            enumCase.attributes,
            description: "enum case",
            at: enumCase,
            in: context
        ) {
            return []
        }
        return enumCase.elements.compactMap { element -> String? in
            if let clause = element.parameterClause {
                var parameters: [ConstExprParameterModel] = []
                var defaultCount = 0
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
                    if defaultExpression != nil { defaultCount += 1 }
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
                            defaultExpression: defaultExpression
                        )
                    )
                }
                guard defaultCount <= 8 else {
                    ConstExprMacroDiagnostic.warning(
                        "associated-value enum case '\(element.name.constExprIdentifier)' has more than eight defaults",
                        id: "too-many-defaults",
                        at: element,
                        in: context
                    )
                    return nil
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
                let names = ConstExprAdapterNames(
                    parameterCount: parameters.count,
                    context: context
                )
                let invocationBody = ConstExprSyntaxSupport.nativeDefaultInvocationBody(
                    callable: callable,
                    names: names
                ) { included in
                    let arguments = ConstExprSyntaxSupport.labeledCallArguments(
                        for: parameters,
                        names: names,
                        including: included
                    )
                    return "\(owner).\(element.name.constExprIdentifierReference)(\(arguments))"
                }
                return registrationSource(
                    name: element.name.constExprIdentifier,
                    kind: ".staticMethod",
                    owner: owner,
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
                callable: callable,
                names: names,
                invocationBody: "return _ConstExprRuntime.Value((\(owner).\(element.name.constExprIdentifierReference)) as Any, preservingStaticType: \(ConstExprSyntaxSupport.metatypeSource(for: owner)), sourceTypeName: \(ConstExprSyntaxSupport.sourceTypeNameSource(for: owner)), isStaticallyAnyObject: \(ConstExprSyntaxSupport.staticallyAnyObjectSource(for: owner)))",
                requiresReceiver: false
            )
        }
    }

    private static func subscriptRegistration(
        _ subscriptDecl: SubscriptDeclSyntax,
        owner: String,
        nominalContext: ConstExprNominalContext,
        providerAccess: ConstExprAccessLevel,
        requiresFinalInstanceMembers: Bool,
        in context: some MacroExpansionContext
    ) -> String? {
        if rejectUnsafeMemberAttributes(
            subscriptDecl.attributes,
            description: "subscript",
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
               guard let modifier = accessor.modifier?.name.text else { return false }
               return modifier == "mutating" || modifier == "consuming"
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
                    defaultExpression: model.defaultExpression
                )
            }
            let callable = ConstExprCallableModel(
                parameters: parameters,
                resultType: originalCallable.resultType,
                resultTypeDescriptor: originalCallable.resultTypeDescriptor,
                isThrowing: false
            )
            let names = ConstExprAdapterNames(
                parameterCount: parameters.count,
                context: context
            )
            let invocationBody = ConstExprSyntaxSupport.nativeDefaultInvocationBody(
                callable: callable,
                names: names
            ) { included in
                let arguments = ConstExprSyntaxSupport.labeledCallArguments(
                    for: parameters,
                    names: names,
                    including: included
                )
                return "\(names.instance)[\(arguments)]"
            }
            return registrationSource(
                name: "subscript",
                kind: ".subscriptGetter",
                owner: owner,
                callable: callable,
                names: names,
                invocationBody: invocationBody,
                requiresReceiver: true
            )
        }
    }

    private static func isIdentifier(_ token: TokenSyntax) -> Bool {
        if case .identifier = token.tokenKind {
            return true
        }
        return false
    }

    private static func registrationSource(
        name: String,
        kind: String,
        owner: String,
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
            resultTypeDescriptor: \(callable.resultTypeDescriptor),\(throwingArgument)
            invoke: { \(names.receiver), \(names.arguments) in
        \(setup)
            }
        )
        """
    }
}
