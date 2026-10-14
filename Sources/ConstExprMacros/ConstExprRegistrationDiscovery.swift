import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// Source-only discovery uses the same expansion entry points as the compiler.
/// Generated adapters are inspected as syntax; neither adapters nor library
/// declarations are executed by discovery.
package enum ConstExprRegistrationDiscovery {
    package struct Entry {
        package enum Kind {
            case root(String)
            case declaration(String)
            case namedExtension(owner: String, name: String)
        }
        package let kind: Kind
        package let declaration: DeclSyntax
        package let owner: String?
        package let registrationKeys: Set<String>
    }

    package static func entries(
        for declaration: DeclSyntax,
        attribute: AttributeSyntax,
        sameModule: Bool,
        in context: some MacroExpansionContext
    ) throws -> [Entry] {
        let minimum: ConstExprAccessLevel = sameModule ? .internal : .package
        if let extended = declaration.as(ExtensionDeclSyntax.self) {
            let owner = extended.extendedType.constExprSource
            if case .argumentList(let arguments) = attribute.arguments,
               arguments.contains(where: { $0.label?.constExprIdentifier == "named" })
            {
                let peers = try ConstExprMembersMacro.expansion(
                    of: attribute, providingMembersOf: extended,
                    conformingTo: [], in: context
                )
                guard let peer = peers.first,
                      accessible(peer, original: declaration, minimum: minimum, in: context),
                      let name = ConstExprMacro.namedExtensionName(from: attribute, in: context)
                else { return [] }
                return [Entry(
                    kind: .namedExtension(owner: owner, name: name),
                    declaration: declaration, owner: owner,
                    registrationKeys: keys(in: peer)
                )]
            }
            var result: [Entry] = []
            // Asking the actual member macro about one member at a time retains
            // its eligibility, inherited attributes, and access-level rules.
            for member in extended.memberBlock.members {
                var single = extended
                single.memberBlock.members = MemberBlockItemListSyntax([member])
                let peers = try ConstExprMembersMacro.expansion(
                    of: attribute, providingMembersOf: single,
                    conformingTo: [], in: context
                )
                result += selections(
                    for: member.decl, peers: peers, owner: owner,
                    minimum: minimum, in: context
                )
            }
            return result
        }
        let peers = try ConstExprMacro.expansion(
            of: attribute, providingPeersOf: declaration, in: context
        )
        if peers.isEmpty {
            report("annotated declaration has no selectable registration provider", at: declaration, in: context)
        }
        return selections(
            for: declaration, peers: peers, owner: enclosingOwner(of: declaration),
            minimum: minimum, in: context
        )
    }

    private static func selections(
        for declaration: DeclSyntax,
        peers: [DeclSyntax],
        owner: String?,
        minimum: ConstExprAccessLevel,
        in context: some MacroExpansionContext
    ) -> [Entry] {
        var result: [Entry] = []
        for peer in peers {
            guard accessible(peer, original: declaration, minimum: minimum, in: context) else { continue }
            let prefix = owner.map { "\($0)." } ?? ""
            let kind: Entry.Kind
            if let name = nominalName(declaration) {
                kind = .root(prefix + name)
            } else if let helper = peer.as(FunctionDeclSyntax.self),
                      let parameter = helper.signature.parameterClause.parameters.first
            {
                if let function = declaration.as(FunctionDeclSyntax.self) {
                    let labels = referenceLabels(function.signature.parameterClause.parameters)
                    let reference = prefix + function.name.constExprIdentifierReference + labels
                    kind = .declaration("\(reference) as \(selectorType(parameter.type))")
                } else if let initializer = declaration.as(InitializerDeclSyntax.self) {
                    let labels = referenceLabels(initializer.signature.parameterClause.parameters)
                    kind = .declaration("\(prefix)init\(labels) as \(selectorType(parameter.type))")
                } else if let variable = declaration.as(VariableDeclSyntax.self),
                          let binding = variable.bindings.first,
                          let identifier = binding.pattern.as(IdentifierPatternSyntax.self)
                {
                    let reference = prefix + identifier.identifier.constExprIdentifierReference
                    let isInstance = owner != nil
                        && !variable.modifiers.constExprContains(.static)
                        && !variable.modifiers.constExprContains(.class)
                    kind = .declaration(isInstance ? "\\\(reference)" : reference)
                } else if declaration.is(SubscriptDeclSyntax.self),
                          let metatype = parameter.type.as(MetatypeTypeSyntax.self)
                {
                    let reference = prefix + helper.name.constExprIdentifierReference
                    kind = .declaration("\(reference)(\(parameter.firstName.text): (\(metatype.baseType.constExprSource)).self)")
                } else {
                    report("cannot form a registry selector for this generated peer", at: declaration, in: context)
                    continue
                }
            } else {
                report("unrecognized registration provider shape", at: declaration, in: context)
                continue
            }
            result.append(Entry(
                kind: kind, declaration: declaration, owner: owner,
                registrationKeys: keys(in: peer)
            ))
        }
        return result
    }

    private static func accessible(
        _ peer: DeclSyntax,
        original: DeclSyntax,
        minimum: ConstExprAccessLevel,
        in context: some MacroExpansionContext
    ) -> Bool {
        let modifiers: DeclModifierListSyntax
        if let function = peer.as(FunctionDeclSyntax.self) { modifiers = function.modifiers }
        else if let enumeration = peer.as(EnumDeclSyntax.self) { modifiers = enumeration.modifiers }
        else { return false }
        guard modifiers.constExprAccessLevel >= minimum else {
            report(
                "registration provider is not visible from the output target; expose the declaration and its enclosing types as package/public (or generate in the same module for internal declarations)",
                at: original, in: context
            )
            return false
        }
        var current = original.parent
        while let node = current {
            let enclosingModifiers: DeclModifierListSyntax?
            if let decl = node.as(StructDeclSyntax.self) { enclosingModifiers = decl.modifiers }
            else if let decl = node.as(ClassDeclSyntax.self) { enclosingModifiers = decl.modifiers }
            else if let decl = node.as(EnumDeclSyntax.self) { enclosingModifiers = decl.modifiers }
            else { enclosingModifiers = nil }
            if let enclosingModifiers, enclosingModifiers.constExprAccessLevel < minimum {
                report("an enclosing type makes this registration inaccessible to the output target", at: original, in: context)
                return false
            }
            current = node.parent
        }
        // A source-only command has no authoritative target build configuration
        // or deployment environment. Never silently drop or unguard these peers.
        if peer.constExprAttributes.contains(where: { element in
            guard let attribute = element.as(AttributeSyntax.self) else { return false }
            return ["available", "_spi"].contains(attribute.attributeName.constExprSource.split(separator: ".").last.map(String.init) ?? "")
        }) {
            report("availability- or SPI-gated registration providers need an explicitly guarded manual registry", at: original, in: context)
            return false
        }
        return true
    }

    private static func selectorType(_ syntax: TypeSyntax) -> String {
        if let attributed = syntax.as(AttributedTypeSyntax.self) {
            return attributed.baseType.constExprSource
        }
        return syntax.constExprSource
    }

    private static func referenceLabels(_ parameters: FunctionParameterListSyntax) -> String {
        guard !parameters.isEmpty else { return "" }
        return "(" + parameters.map { $0.firstName.constExprIdentifierReference + ":" }.joined() + ")"
    }

    private static func nominalName(_ declaration: DeclSyntax) -> String? {
        if let decl = declaration.as(StructDeclSyntax.self) { return decl.name.constExprIdentifierReference }
        if let decl = declaration.as(ClassDeclSyntax.self) { return decl.name.constExprIdentifierReference }
        if let decl = declaration.as(EnumDeclSyntax.self) { return decl.name.constExprIdentifierReference }
        return nil
    }

    private static func enclosingOwner(of declaration: DeclSyntax) -> String? {
        var components: [String] = []
        var current = declaration.parent
        while let node = current {
            if let decl = node.as(DeclSyntax.self), let name = nominalName(decl) { components.append(name) }
            if let decl = node.as(ExtensionDeclSyntax.self) {
                components.append(decl.extendedType.constExprSource)
                break
            }
            current = node.parent
        }
        return components.isEmpty ? nil : components.reversed().joined(separator: ".")
    }

    private static func keys(in declaration: DeclSyntax) -> Set<String> {
        let visitor = RegistrationKeys(viewMode: .sourceAccurate)
        visitor.walk(declaration)
        return visitor.keys
    }

    private final class RegistrationKeys: SyntaxVisitor {
        var keys: Set<String> = []
        override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
            if node.calledExpression.constExprSource == "_ConstExprRuntime.Registration" {
                let identity = Set(["name", "kind", "ownerType", "parameterLabels", "parameterTypes", "resultType"])
                let arguments = node.arguments.filter { identity.contains($0.label?.text ?? "") }
                    .map { $0.with(\.trailingComma, nil).trimmedDescription }
                    .joined(separator: ", ")
                keys.insert("_ConstExprRuntime.Registration(\(arguments))")
            }
            return .visitChildren
        }
    }

    private static func report(_ message: String, at node: some SyntaxProtocol, in context: some MacroExpansionContext) {
        ConstExprMacroDiagnostic.error(message, id: "registry-discovery", at: node, in: context)
    }
}
