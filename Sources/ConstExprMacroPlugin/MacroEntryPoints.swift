import ConstExprMacroImplementation
import SwiftSyntax
import SwiftSyntaxMacros

// Keep the existing external macro module/type identities. The compiler plugin
// resolves these reflected names, while discovery links the shared implementation.
public struct ConstExprMacro: PeerMacro {
    public static func expansion(
        of attribute: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        try ConstExprMacroImplementation.ConstExprMacro.expansion(
            of: attribute, providingPeersOf: declaration, in: context
        )
    }
}

public struct ConstExprMembersMacro: MemberMacro {
    public static func expansion(
        of attribute: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        try ConstExprMacroImplementation.ConstExprMembersMacro.expansion(
            of: attribute, providingMembersOf: declaration,
            conformingTo: protocols, in: context
        )
    }
}

public struct ConstExprIgnoredMacro: PeerMacro {
    public static func expansion(
        of attribute: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        try ConstExprMacroImplementation.ConstExprIgnoredMacro.expansion(
            of: attribute, providingPeersOf: declaration, in: context
        )
    }
}

public struct ConstExprRegistryMacro: ExpressionMacro {
    public static func expansion(
        of macro: some FreestandingMacroExpansionSyntax,
        in context: some MacroExpansionContext
    ) throws -> ExprSyntax {
        try ConstExprMacroImplementation.ConstExprRegistryMacro.expansion(of: macro, in: context)
    }
}
