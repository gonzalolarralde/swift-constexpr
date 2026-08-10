import SwiftSyntaxMacrosTestSupport

extension ConstExprMacroTests {
    func testNestedNominalInExtensionProviderSnapshot() {
        assertMacroExpansion(
            """
            public enum Namespace {}

            extension Namespace {
                @ConstExpr(registrationAccess: .package)
                public struct Version {}
            }
            """,
            expandedSource: """
            public enum Namespace {}

            extension Namespace {
                public struct Version {}

                package enum Version__constExpr {
                    package static var registrations: [Any] {
                        [

                        ]
                    }
                }
            }
            """,
            macros: macros
        )
    }
}
