import ConstExprMacroSupport
import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxMacros

public struct PacketBytesMacro: ExpressionMacro {
    private static let registry = PacketKitRegistry.value

    public static func expansion(
        of macro: some FreestandingMacroExpansionSyntax,
        in context: some MacroExpansionContext
    ) throws -> ExprSyntax {
        expansion(of: macro, in: context, policy: .bestEffort)
    }

    fileprivate static func expansion(
        of macro: some FreestandingMacroExpansionSyntax,
        in context: some MacroExpansionContext,
        policy: ConstExprMacroEvaluationPolicy
    ) -> ExprSyntax {
        ConstExprBuilderMacroSupport.expansion(
            of: macro,
            in: context,
            registry: registry,
            builderType: "PacketBuilder",
            runtimeFunction: "PacketKit.Packet.encode",
            runtimeBuilderType: "PacketKit.PacketBuilder",
            policy: policy
        )
    }
}

public struct PacketConstBytesMacro: ExpressionMacro {
    public static func expansion(
        of macro: some FreestandingMacroExpansionSyntax,
        in context: some MacroExpansionContext
    ) throws -> ExprSyntax {
        PacketBytesMacro.expansion(of: macro, in: context, policy: .requireConstant)
    }
}

@main
struct PacketKitPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [PacketBytesMacro.self, PacketConstBytesMacro.self]
}
