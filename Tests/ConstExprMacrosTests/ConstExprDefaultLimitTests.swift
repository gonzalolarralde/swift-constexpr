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

            enum TooManyDefaults__constExpr {
                static var registrations: [_ConstExprRuntime.Registration] {
                    [

                    ]
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "initializer was not registered because its 9 default arguments include a non-literal expression and exceed the automatic omission limit of eight; provide a manual label-keyed ConstExprRegistration adapter",
                    line: 7,
                    column: 5,
                    severity: .warning
                )
            ],
            macros: macros
        )
    }
}
