import SwiftDiagnostics
import SwiftSyntaxMacrosTestSupport

extension ConstExprMacroTests {
    func testDirectMembersRejectPotentialDynamicClassDispatch() {
        assertMacroExpansion(
            """
            class Base {
                @ConstExpr
                func value() -> Int { 1 }
            }
            """,
            expandedSource: """
            class Base {
                func value() -> Int { 1 }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "overridable instance method 'value' was not registered; mark the class or member final to prevent dispatch to an unregistered override",
                    line: 2,
                    column: 5,
                    severity: .warning
                )
            ],
            macros: macros
        )

        assertMacroExpansion(
            """
            class Base {
                @ConstExpr
                var value: Int { 1 }
            }
            """,
            expandedSource: """
            class Base {
                var value: Int { 1 }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "overridable instance property was not registered; mark the class or property final to prevent dispatch to an unregistered override",
                    line: 2,
                    column: 5,
                    severity: .warning
                )
            ],
            macros: macros
        )

        assertMacroExpansion(
            """
            class Base {
                @ConstExpr
                subscript(index: Int) -> Int { index }
            }
            """,
            expandedSource: """
            class Base {
                subscript(index: Int) -> Int { index }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "overridable instance subscript was not registered; mark the class or subscript final to prevent dispatch to an unregistered override",
                    line: 2,
                    column: 5,
                    severity: .warning
                )
            ],
            macros: macros
        )
    }

    func testDirectExtensionInstanceMemberRequiresExplicitFinality() {
        assertMacroExpansion(
            """
            struct Value {}
            extension Value {
                @ConstExpr
                func answer() -> Int { 42 }
            }
            """,
            expandedSource: """
            struct Value {}
            extension Value {
                func answer() -> Int { 42 }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "overridable instance method 'answer' was not registered; mark the class or member final to prevent dispatch to an unregistered override",
                    line: 3,
                    column: 5,
                    severity: .warning
                )
            ],
            macros: macros
        )
    }
}
