import SwiftSyntaxMacrosTestSupport

extension ConstExprMacroTests {
    func testNamedExtensionEmitsOneOwnerScopedProvider() {
        assertMacroExpansion(
            """
            @ConstExprMembers(named: "Networking")
            extension Client {}
            """,
            expandedSource: """
            extension Client {

                static func __constExprRegistration_Networking(
                    _: Client__constExpr.Type
                ) -> [Any] {
                    [

                    ]
                }
            }
            """,
            macros: macros
        )
    }

    func testNamedExtensionRequiresAnIdentifierLiteral() {
        assertMacroExpansion(
            """
            @ConstExprMembers(named: "not a name")
            extension Client {}
            """,
            expandedSource: "extension Client {}",
            diagnostics: [
                DiagnosticSpec(
                    message: "named must be a non-interpolated string literal containing a Swift identifier",
                    line: 1,
                    column: 26
                )
            ],
            macros: macros
        )
    }
}
