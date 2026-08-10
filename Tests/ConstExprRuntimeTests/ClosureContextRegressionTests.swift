import Testing
@testable import ConstExpr

@Test func implicitClosureReturnsPreserveTheirCallerSuppliedLiteralContext() {
    let source = """
        let implicit = consume(transform: { return 255 &+ 1 })
        let explicit = consume(transform: { () -> UInt8 in return 255 &+ 1 })
        """

    let result = ConstExprRunner(registry: .empty).rewrite(source: source)

    #expect(result.source == """
        let implicit = consume(transform: { return 255 &+ 1 })
        let explicit = consume(transform: { () -> UInt8 in return (0) as Swift.UInt8 })
        """)
    #expect(result.diagnostics.isEmpty)
}
