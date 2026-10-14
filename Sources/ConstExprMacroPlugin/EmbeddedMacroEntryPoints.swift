import SwiftSyntax
import SwiftSyntaxMacros

/// Selected by the declaration module's Embedded build, not by this host plugin.
public struct ConstExprNoOpPeerMacro: PeerMacro {
    public static func expansion(
        of attribute: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] { [] }
}

public struct ConstExprNoOpMemberMacro: MemberMacro {
    public static func expansion(
        of attribute: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] { [] }
}
