import ConstExprMacros
import SwiftParser
import SwiftSyntax
import SwiftSyntaxMacroExpansion
import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import XCTest

final class ConstExprGeneratedChunkExpansionTests: XCTestCase {
    private let macros: [String: Macro.Type] = [
        "ConstExpr": ConstExprMacro.self,
        "constExprRegistry": ConstExprRegistryMacro.self,
    ]

    func testLargeNominalExpansionUsesStableProviderChunks() {
        let members = (0..<65).map {
            "    static func \(numbered("entry", $0))() -> Int { \($0) }"
        }.joined(separator: "\n")
        let expanded = expand("""
        @ConstExpr
        struct LargeProvider {
        \(members)
        }
        """)

        XCTAssertTrue(expanded.contains("private static var __constExprRegistrationChunk0"))
        XCTAssertTrue(expanded.contains("private static var __constExprRegistrationChunk1"))
        XCTAssertTrue(expanded.contains("private static var __constExprRegistrationChunk2"))
        XCTAssertTrue(expanded.contains("flatMap"), expanded)
        assertRegistrationNames(
            (0..<65).map { numbered("entry", $0) },
            appearInOrderIn: expanded
        )
    }

    func testLargeFreestandingExpansionUsesBoundedConcatenation() {
        let arguments = (0..<33).map {
            numbered("value", $0)
        }.joined(separator: ", ")
        let expanded = expand(
            "let registry = #constExprRegistry(\(arguments))"
        )

        XCTAssertEqual(
            expanded.components(separatedBy: "registrations(fromGeneratedPeer:").count - 1,
            33
        )
        XCTAssertEqual(
            expanded.components(separatedBy: "flatMap").count - 1,
            2,
            expanded
        )
        XCTAssertFalse(expanded.contains(" + "))
    }

    private func expand(_ source: String) -> String {
        let sourceFile = Parser.parse(source: source)
        let context = BasicMacroExpansionContext(
            sourceFiles: [
                sourceFile: .init(moduleName: "ChunkTests", fullFilePath: "test.swift")
            ]
        )
        let expanded = sourceFile.expand(
            macros: macros,
            contextGenerator: { syntax in
                BasicMacroExpansionContext(
                    sharingWith: context,
                    lexicalContext: syntax.allMacroLexicalContexts()
                )
            },
            indentationWidth: .spaces(4)
        )
        XCTAssertTrue(context.diagnostics.isEmpty)
        return expanded.description
    }

    private func assertRegistrationNames(
        _ names: [String],
        appearInOrderIn source: String
    ) {
        var remainder = source[...]
        for name in names {
            let needle = "name: \(String(reflecting: name))"
            guard let range = remainder.range(of: needle) else {
                XCTFail("missing generated registration for \(name)")
                return
            }
            remainder = remainder[range.upperBound...]
        }
    }

    private func numbered(_ prefix: String, _ index: Int) -> String {
        prefix + (index < 10 ? "0" : "") + String(index)
    }
}
