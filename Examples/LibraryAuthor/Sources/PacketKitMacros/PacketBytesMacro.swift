import ConstExpr
import ConstExprMacroSupport
import PacketKitModel
import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxMacros

public struct PacketBytesMacro: ExpressionMacro {
    private static let registry = #constExprRegistry(
        Packet.self, Packet.ByteOrder.self, GIF.self,
        PacketBuilder.buildExpression(_:),
        PacketBuilder.buildPartialBlock(first:),
        PacketBuilder.buildPartialBlock(accumulated:next:),
        PacketBuilder.buildFinalResult(_:),
        PacketBuilder.buildBlock
    )

    public static func expansion(
        of macro: some FreestandingMacroExpansionSyntax,
        in context: some MacroExpansionContext
    ) throws -> ExprSyntax {
        ConstExprBuilderMacroSupport.expansion(
            of: macro,
            in: context,
            registry: registry,
            builderType: "PacketBuilder",
            runtimeFunction: "Packet.encode",
            requireConstantArgumentLabel: "requireConstant"
        )
    }
}

@main
struct PacketKitPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [PacketBytesMacro.self]
}
