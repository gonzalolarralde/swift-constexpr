import Foundation
import PacketKitMacros
import SwiftParser
import SwiftSyntax
import SwiftSyntaxMacroExpansion
import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import XCTest

final class PacketBytesMacroTests: XCTestCase {
    private let macros: [String: Macro.Type] = [
        "packetBytes": PacketBytesMacro.self,
        "packetConstBytes": PacketConstBytesMacro.self,
    ]

    func testTypedFieldsAndArrayExpandToLiteralBytes() {
        assertMacroExpansion(
            """
            let bytes = #packetConstBytes {
                let payload: [UInt8] = [3, 4]
                Packet.UInt16(0x1234, order: .littleEndian)
                Packet.UInt8(2)
                Packet.Bytes(payload)
            }
            """,
            expandedSource: """
            let bytes = ([52, 18, 2, 3, 4]) as [UInt8]
            """,
            macros: macros
        )
    }

    func testMixedBodyFoldsStaticFieldsOnBothSidesOfRuntimeCapture() {
        let (expanded, context) = expand(
            """
            let bytes = #packetBytes {
                Packet.UInt16(0xCAFE, order: .bigEndian)
                Packet.UInt8(opcode)
                Packet.Bytes([3, 4])
                Packet.UInt16(0xBEEF, order: .bigEndian)
            }
            """
        )
        XCTAssertTrue(context.diagnostics.isEmpty, "\(context.diagnostics)")
        XCTAssertTrue(expanded.description.contains("Packet.UInt8(opcode)"))
        XCTAssertFalse(expanded.description.contains("Packet.UInt16("))
        XCTAssertFalse(expanded.description.contains("Packet.Bytes("))
        XCTAssertEqual(expanded.description.components(separatedBy: ".buildExpression(").count - 1, 1)
        XCTAssertTrue(expanded.description.contains("= PacketKit.PacketBuilder"))
        XCTAssertFalse(expanded.description.contains("as Swift.UInt8"))
        let visitor = LiteralBytesVisitor(viewMode: .sourceAccurate)
        visitor.walk(expanded)
        XCTAssertEqual(visitor.bytes, [202, 254, 3, 4, 190, 239])
    }

    func testKnownArgumentsInsideADynamicConsumerCallAreFolded() {
        let (expanded, context) = expand("""
        let bytes = #packetBytes {
            combine(Packet.UTF8("AB"), payload)
        }
        """)
        XCTAssertTrue(context.diagnostics.isEmpty, "\(context.diagnostics)")
        XCTAssertTrue(expanded.description.contains("combine("))
        XCTAssertTrue(expanded.description.contains("payload"))
        XCTAssertFalse(expanded.description.contains("Packet.UTF8("))
        let visitor = LiteralBytesVisitor(viewMode: .sourceAccurate)
        visitor.walk(expanded)
        XCTAssertEqual(visitor.bytes, [65, 66])
    }

    func testInferredConstantArrayBindingStillFoldsInAMixedBody() {
        let (expanded, context) = expand("""
        let bytes = #packetBytes {
            let header = Packet.UTF8("AB")
            Packet.Bytes(header)
            Packet.UInt8(opcode)
        }
        """)
        XCTAssertTrue(context.diagnostics.isEmpty, "\(context.diagnostics)")
        XCTAssertFalse(expanded.description.contains("Packet.UTF8("), expanded.description)
        XCTAssertFalse(expanded.description.contains("Packet.Bytes("), expanded.description)
        XCTAssertTrue(expanded.description.contains(".buildExpression(Packet.UInt8(opcode))"))
    }

    func testStrictMixedBodyReportsAnError() {
        let (_, context) = expand("""
        let bytes = #packetConstBytes {
            Packet.UTF8("PKT")
            Packet.UInt8(opcode)
        }
        """)
        XCTAssertEqual(context.diagnostics.count, 1)
        XCTAssertTrue(context.diagnostics[0].message.hasPrefix("#packetConstBytes could not produce a compile-time constant:"))
    }

    func testConsumerHelperNeedsNoRegistrationAtRuntime() {
        assertMacroExpansion(
            "let bytes = #packetBytes { makeBytes() }",
            expandedSource: """
            let bytes = PacketKit.Packet.encode {
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
        let (expanded, context) = expand(source)
        XCTAssertTrue(context.diagnostics.isEmpty, "\(context.diagnostics)")
        let visitor = LiteralBytesVisitor(viewMode: .sourceAccurate)
        visitor.walk(expanded)
        XCTAssertEqual(visitor.arrayCount, 1)
        XCTAssertEqual(visitor.callCount, 0, "No encoder or builder calls may survive expansion")
        XCTAssertEqual(visitor.macroCount, 0)
        XCTAssertEqual(visitor.bytes.count, 1625)
        XCTAssertEqual(Array(visitor.bytes.prefix(6)), Array("GIF89a".utf8))
        XCTAssertEqual(visitor.bytes.last, 0x3B)
        XCTAssertFalse(expanded.description.contains("as Swift.UInt8"))
    }

    private func expand(_ source: String) -> (Syntax, BasicMacroExpansionContext) {
        let tree = Parser.parse(source: source)
        let context = BasicMacroExpansionContext()
        let expanded = tree.expand(
            macros: macros,
            contextGenerator: { syntax in
                BasicMacroExpansionContext(sharingWith: context, lexicalContext: syntax.allMacroLexicalContexts())
            },
            indentationWidth: .spaces(4)
        )
        return (Syntax(expanded), context)
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
