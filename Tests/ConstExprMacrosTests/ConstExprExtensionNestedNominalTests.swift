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

                package enum Version__constExpr: _ConstExprRuntime.RegistrationProviding {
                    package static var registrations: [Any] {
                        [

                        ]
                    }

                    package typealias Owner = Version

                    package static var constExprRegistrations: [Any] {
                        registrations.map {
                            $0 as Any
                        }
                    }
                }
            }
            """,
            macros: macros
        )
    }
}
