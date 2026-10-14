import Foundation
import PacketKitMacros
import SwiftParser
import SwiftSyntax
import SwiftSyntaxMacroExpansion
import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import XCTest

final class PacketBytesMacroTests: XCTestCase {
    private let macros: [String: Macro.Type] = ["packetBytes": PacketBytesMacro.self]

    func testTypedFieldsAndArrayExpandToLiteralBytes() {
        assertMacroExpansion(
            """
            let bytes = #packetBytes(requireConstant: true) {
                let payload: [UInt8] = [3, 4]
                Packet.UInt16(0x1234, order: .littleEndian)
                Packet.UInt8(2)
                Packet.Bytes(payload)
            }
            """,
            expandedSource: """
            let bytes = ([(52) as Swift.UInt8, (18) as Swift.UInt8, (2) as Swift.UInt8, (3) as Swift.UInt8, (4) as Swift.UInt8]) as [UInt8]
            """,
            macros: macros
        )
    }

    func testRuntimeCaptureKeepsTheWholeBuilder() {
        assertMacroExpansion(
            """
            let bytes = #packetBytes {
                Packet.UInt8(opcode)
                Packet.Bytes([3, 4])
            }
            """,
            expandedSource: """
            let bytes = Packet.encode {
                Packet.UInt8(opcode)
                Packet.Bytes([3, 4])
            }
            """,
            macros: macros
        )
    }

    func testConsumerHelperNeedsNoRegistrationAtRuntime() {
        assertMacroExpansion(
            "let bytes = #packetBytes { makeBytes() }",
            expandedSource: """
            let bytes = Packet.encode {
                makeBytes()
            }
            """,
            macros: macros
        )
    }

    func testTheActualCLIAnimationBecomesOnlyLiteralBytes() throws {
        // Read the actual CLI source so this guarantee cannot drift from the demo.
        let examples = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: examples.appendingPathComponent("Consumer/Sources/PacketDemo/Animation.swift"),
            encoding: .utf8
        )
        let tree = Parser.parse(source: source)
        let context = BasicMacroExpansionContext()
        let expanded = tree.expand(
            macros: macros,
            contextGenerator: { syntax in
                BasicMacroExpansionContext(sharingWith: context, lexicalContext: syntax.allMacroLexicalContexts())
            },
            indentationWidth: .spaces(4)
        )
        XCTAssertTrue(context.diagnostics.isEmpty, "\(context.diagnostics)")
        let visitor = LiteralBytesVisitor(viewMode: .sourceAccurate)
        visitor.walk(expanded)
        XCTAssertEqual(visitor.arrayCount, 1)
        XCTAssertEqual(visitor.callCount, 0, "No encoder or builder calls may survive expansion")
        XCTAssertEqual(visitor.macroCount, 0)
        XCTAssertEqual(visitor.bytes.count, 1625)
        XCTAssertEqual(Array(visitor.bytes.prefix(6)), Array("GIF89a".utf8))
        XCTAssertEqual(visitor.bytes.last, 0x3B)
    }
}

private final class LiteralBytesVisitor: SyntaxVisitor {
    var arrayCount = 0
    var callCount = 0
    var macroCount = 0
    var bytes: [UInt8] = []

    override func visit(_ node: ArrayExprSyntax) -> SyntaxVisitorContinueKind {
        arrayCount += 1
        return .visitChildren
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        callCount += 1
        return .visitChildren
    }

    override func visit(_ node: MacroExpansionExprSyntax) -> SyntaxVisitorContinueKind {
        macroCount += 1
        return .visitChildren
    }

    override func visit(_ node: IntegerLiteralExprSyntax) -> SyntaxVisitorContinueKind {
        if let byte = UInt8(node.literal.text) { bytes.append(byte) }
        return .visitChildren
    }
}
