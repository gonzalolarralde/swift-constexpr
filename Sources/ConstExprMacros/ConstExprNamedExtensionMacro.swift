import Foundation
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

extension ConstExprMacro {
    static func expandNamedExtensionMembers(
        _ extensionDecl: ExtensionDeclSyntax,
        name: String,
        registrationAccess: ConstExprRegistrationAccessOption,
        attribute: AttributeSyntax,
        in context: some MacroExpansionContext
    ) -> [DeclSyntax] {
        guard extensionDecl.genericWhereClause == nil else {
            ConstExprMacroDiagnostic.error(
                "named @ConstExpr extensions cannot have a generic where clause",
                id: "named-extension-generic-context",
                at: attribute,
                in: context
            )
            return []
        }
        let genericArguments = ConstExprGenericArgumentVisitor()
        genericArguments.walk(extensionDecl.extendedType)
        guard !genericArguments.found else {
            ConstExprMacroDiagnostic.error(
                "named @ConstExpr extensions cannot extend a specialized generic type",
                id: "named-extension-generic-context",
                at: attribute,
                in: context
            )
            return []
        }

        let owner = extensionDecl.extendedType.constExprSource
        let rootProvider = suffixedOwnerReference(owner)
        let nominalContext = ConstExprNominalContext(
            ownerReference: owner,
            localTypeNames: []
        )
        let inheritedAttributes = extensionDecl.attributes.filter {
            guard let attribute = $0.as(AttributeSyntax.self) else { return false }
            let name = attribute.attributeName.constExprSource
            return name == "available" || name == "_spi"
        }
        var registrations: [String] = []

        for item in extensionDecl.memberBlock.members {
            let declaration = item.decl
            let attributes = declaration.constExprAttributes
            if attributes.constExprContainsAttribute(named: "ConstExprIgnored")
                || attributes.constExprContainsAttribute(named: "ConstExpr")
            {
                continue
            }
            let metadata = ConstExprRegistrationMetadataSource(attributes: attributes)
            if metadata.isUnconditionallyUnavailable
                || metadata.hasDeprecatedAvailability
                || metadata.hasObsoletedAvailability
            {
                continue
            }

            ConstExprMacroDiagnostic.suppressing {
                appendNamedExtensionRegistrations(
                    for: declaration,
                    inheritedAttributes: inheritedAttributes,
                    owner: owner,
                    nominalContext: nominalContext,
                    registrations: &registrations,
                    in: context
                )
            }
        }

        let requestedAccess: String
        switch registrationAccess {
        case .package:
            // The named fragment is designed to be selected by a sibling host
            // target. Its owner provider is package-scoped as well.
            requestedAccess = "package "
        case .declaration:
            requestedAccess = registrationAccess.accessPrefix(
                declarationModifiers: extensionDecl.modifiers
            )
        }
        // A private type member is visible only inside the nominal's lexical
        // scope, while the registry expression is normally file-scoped.
        // File-private retains the same source-file boundary as a private
        // top-level generated provider.
        let access = requestedAccess == "private "
            ? ""
            : requestedAccess
        let registrationsExpression: String
        if registrations.count > ConstExprRegistrationChunkSyntax.limit {
            registrationsExpression = ConstExprRegistrationChunkSyntax
                .boundedConcatenation(
                    registrations.map {
                        "[(\($0) as Any)]"
                    }
                )
        } else {
            let entries = registrations.map {
                ConstExprSyntaxSupport.indent(
                    "(\($0) as Any)",
                    by: 12
                )
            }.joined(separator: ",\n")
            registrationsExpression = """
            [
            \(entries)
                ]
            """
        }
        let preservedAttributes = extensionDecl.attributes
            .constExprPreservedPeerAttributes
        let attributePrefix = preservedAttributes.isEmpty
            ? ""
            : "\(preservedAttributes)\n"
        let source = """
        \(attributePrefix)\(access)static func __constExprRegistration_\(name)(
            _: \(rootProvider).Type
        ) -> [Any] {
            \(registrationsExpression)
        }
        """
        return [DeclSyntax(stringLiteral: source)]
    }

    static func namedExtensionName(
        from attribute: AttributeSyntax,
        in context: some MacroExpansionContext
    ) -> String? {
        guard case .argumentList(let arguments) = attribute.arguments,
              let argument = arguments.first(where: {
                  $0.label?.constExprIdentifier == "named"
              }),
              let literal = argument.expression.as(StringLiteralExprSyntax.self),
              literal.segments.count == 1,
              let segment = literal.segments.first?.as(StringSegmentSyntax.self)
        else {
            ConstExprMacroDiagnostic.error(
                "named must be a non-interpolated string literal containing a Swift identifier",
                id: "invalid-extension-name",
                at: attribute,
                in: context
            )
            return nil
        }
        let name = segment.content.text
        guard isSimpleIdentifier(name) else {
            ConstExprMacroDiagnostic.error(
                "named must be a non-interpolated string literal containing a Swift identifier",
                id: "invalid-extension-name",
                at: argument.expression,
                in: context
            )
            return nil
        }
        return name
    }

    static func isSimpleIdentifier(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first,
              first == "_" || CharacterSet.letters.contains(first)
        else { return false }
        return name.unicodeScalars.dropFirst().allSatisfy {
            $0 == "_" || CharacterSet.alphanumerics.contains($0)
        }
    }

    private static func suffixedOwnerReference(_ owner: String) -> String {
        let separator = owner.lastIndex(of: ".")
        let prefix = separator.map { String(owner[...$0]) } ?? ""
        let leafStart = separator.map { owner.index(after: $0) }
            ?? owner.startIndex
        let leaf = String(owner[leafStart...])
        if leaf.count >= 2, leaf.first == "`", leaf.last == "`" {
            return "\(prefix)`\(leaf.dropFirst().dropLast())__constExpr`"
        }
        return "\(prefix)\(leaf)__constExpr"
    }

    private static func appendNamedExtensionRegistrations(
        for declaration: DeclSyntax,
        inheritedAttributes: AttributeListSyntax,
        owner: String,
        nominalContext: ConstExprNominalContext,
        registrations: inout [String],
        in context: some MacroExpansionContext
    ) {
        // Registration bodies are emitted in the same file and do not expose
        // member declarations in their API. Internal is therefore the correct
        // lower bound; private/fileprivate declarations remain excluded by the
        // ordinary member checks.
        let providerAccess = ConstExprAccessLevel.internal
        if var initializer = declaration.as(InitializerDeclSyntax.self) {
            initializer.attributes = mergedNamedAttributes(
                inheritedAttributes,
                initializer.attributes
            )
            if let registration = initializerRegistration(
                initializer,
                owner: owner,
                nominalContext: nominalContext,
                providerAccess: providerAccess,
                allowsAvailability: true,
                in: context
            ) {
                registrations.append(registration)
            }
            return
        }
        if var function = declaration.as(FunctionDeclSyntax.self) {
            function.attributes = mergedNamedAttributes(
                inheritedAttributes,
                function.attributes
            )
            if let registration = methodRegistration(
                function,
                owner: owner,
                nominalContext: nominalContext,
                providerAccess: providerAccess,
                requiresFinalInstanceMembers: true,
                allowsAvailability: true,
                in: context
            ) {
                registrations.append(registration)
            }
            return
        }
        if var variable = declaration.as(VariableDeclSyntax.self) {
            variable.attributes = mergedNamedAttributes(
                inheritedAttributes,
                variable.attributes
            )
            registrations.append(contentsOf: propertyRegistrations(
                variable,
                owner: owner,
                nominalContext: nominalContext,
                providerAccess: providerAccess,
                requiresFinalInstanceMembers: true,
                allowsAvailability: true,
                in: context
            ))
            return
        }
        if var subscriptDecl = declaration.as(SubscriptDeclSyntax.self) {
            subscriptDecl.attributes = mergedNamedAttributes(
                inheritedAttributes,
                subscriptDecl.attributes
            )
            if let registration = subscriptRegistration(
                subscriptDecl,
                owner: owner,
                nominalContext: nominalContext,
                providerAccess: providerAccess,
                requiresFinalInstanceMembers: true,
                allowsAvailability: true,
                in: context
            ) {
                registrations.append(registration)
            }
        }
    }

    private static func mergedNamedAttributes(
        _ inherited: AttributeListSyntax,
        _ direct: AttributeListSyntax
    ) -> AttributeListSyntax {
        AttributeListSyntax(Array(inherited) + Array(direct))
    }
}
