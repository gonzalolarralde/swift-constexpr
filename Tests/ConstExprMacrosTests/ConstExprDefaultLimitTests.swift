import SwiftSyntaxMacrosTestSupport
import XCTest

extension ConstExprMacroTests {
    func testNonliteralDefaultsBeyondAutomaticLimitAreOmitted() {
        assertMacroExpansion(
            """
            enum Defaults {
                static let value = 0
            }

            @ConstExpr
            struct TooManyDefaults {
                init(
                    a: Int = Defaults.value,
                    b: Int = Defaults.value,
                    c: Int = Defaults.value,
                    d: Int = Defaults.value,
                    e: Int = Defaults.value,
                    f: Int = Defaults.value,
                    g: Int = Defaults.value,
                    h: Int = Defaults.value,
                    i: Int = Defaults.value
                ) {}
            }
            """,
            expandedSource: """
            enum Defaults {
                static let value = 0
            }
            struct TooManyDefaults {
                init(
                    a: Int = Defaults.value,
                    b: Int = Defaults.value,
                    c: Int = Defaults.value,
                    d: Int = Defaults.value,
                    e: Int = Defaults.value,
                    f: Int = Defaults.value,
                    g: Int = Defaults.value,
                    h: Int = Defaults.value,
                    i: Int = Defaults.value
                ) {}
            }

            enum TooManyDefaults__constExpr: _ConstExprRuntime.RegistrationProviding {
                static var registrations: [_ConstExprRuntime.Registration] {
                    [

                    ]
                }

                typealias Owner = TooManyDefaults

                static var constExprRegistrations: [Any] {
                    registrations.map {
                        $0 as Any
                    }
                }
            }
            """,
            macros: macros
        )
    }
}
