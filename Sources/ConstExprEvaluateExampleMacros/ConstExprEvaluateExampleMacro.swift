import ConstExprExampleRegistry
import ConstExprMacroSupport
import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxMacros

public struct ConstExprEvaluateExampleMacro: ExpressionMacro {
    public static func expansion(
        of macro: some FreestandingMacroExpansionSyntax,
        in context: some MacroExpansionContext
    ) throws -> ExprSyntax {
        ConstExprEvaluateMacroSupport.expansion(
            of: macro,
            in: context,
            registry: exampleConstExprRegistry
        )
    }
}

@main
struct ConstExprEvaluateExamplePlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        ConstExprEvaluateExampleMacro.self
    ]
}
