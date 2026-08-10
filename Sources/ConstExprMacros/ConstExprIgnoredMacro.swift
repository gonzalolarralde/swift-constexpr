import SwiftSyntax
import SwiftSyntaxMacros

/// A marker consumed by bulk `@ConstExpr` expansion. It deliberately emits no
/// peer when used on its own.
public struct ConstExprIgnoredMacro: PeerMacro {
    public static func expansion(
        of attribute: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        []
    }
}
