import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct ConstExprPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        ConstExprMacro.self,
        ConstExprMembersMacro.self,
        ConstExprIgnoredMacro.self,
        ConstExprRegistryMacro.self,
    ]
}
