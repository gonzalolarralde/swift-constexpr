import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct ConstExprPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        ConstExprMacro.self,
        ConstExprRegistryMacro.self,
    ]
}
