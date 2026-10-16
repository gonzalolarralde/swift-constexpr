import SwiftSyntax
import Testing
@testable import ConstExpr
@testable import ConstExprEvaluation

struct ArrayRenderedNumber: ConstExprRepresentable {
    func constExprExpression() throws -> ExprSyntax {
        "ArrayRenderedNumber(raw: (7) as Swift.UInt8)"
    }
}

@Test func numericArraysUseTheirOuterTypeForBuiltInLiterals() throws {
    func check<T: ConstExprRepresentable>(_ values: [T], _ body: String) throws {
        let expected = "([\(body)]) as \(String(reflecting: [T].self))"
        #expect(try ConstExprValue(values).renderSource() == expected)
        #expect(try values.constExprExpression().description == expected)
    }
    try check([Int.min, Int.max], "\(Int.min), \(Int.max)")
    try check([Int8.min, Int8.max], "-128, 127")
    try check([Int16.min, Int16.max], "-32768, 32767")
    try check([Int32.min, Int32.max], "-2147483648, 2147483647")
    try check([Int64.min, Int64.max], "-9223372036854775808, 9223372036854775807")
    try check([UInt.min, UInt.max], "0, \(UInt.max)")
    try check([UInt8.min, UInt8.max], "0, 255")
    try check([UInt16.min, UInt16.max], "0, 65535")
    try check([UInt32.min, UInt32.max], "0, 4294967295")
    try check([UInt64.min, UInt64.max], "0, 18446744073709551615")
    try check([Float(-0.0), 1.5], "-0.0, 1.5")
    try check([Double(-0.0), 1.5], "-0.0, 1.5")
    try check([UInt8](), "")
}

@Test func structuralNumericArraysRequireMatchingExplicitElementContext() throws {
    let bytes = [ConstExprValue(UInt8(7)), ConstExprValue(UInt8(255))]
    for spelling in ["[UInt8]", "[Swift.UInt8]", "Swift.Array<Swift.UInt8>"] {
        #expect(try ConstExprValue.array(bytes, typeName: spelling).renderSource()
            == "([7, 255]) as \(spelling)")
    }
    for spelling in ["[Any]", "[any BinaryInteger]", "[Other.UInt8]", "Bytes"] {
        #expect(try ConstExprValue.array(bytes, typeName: spelling).renderSource()
            == "([(7) as Swift.UInt8, (255) as Swift.UInt8]) as \(spelling)")
    }
    #expect(try ConstExprValue.array(bytes).renderSource()
        == "[(7) as Swift.UInt8, (255) as Swift.UInt8]")
    #expect(try ConstExprValue(UInt8(7)).renderSource() == "(7) as Swift.UInt8")
    #expect(try UInt8(7).constExprExpression().description == "(7) as Swift.UInt8")
}

@Test func numericArrayRenderingPreservesErasedAndCustomElements() throws {
    let erased: [Any] = [UInt8(7), Int16(-2), Float(1.5)]
    let source = try ConstExprValue(erased).renderSource()
    #expect(source.contains("(7) as Swift.UInt8"))
    #expect(source.contains("(-2) as Swift.Int16"))
    #expect(source.contains("(1.5) as Swift.Float"))
    let existential: [any BinaryInteger] = [UInt8(7)]
    #expect(try ConstExprValue(existential).renderSource().contains("(7) as Swift.UInt8"))
    let optional: [UInt8?] = [7, nil]
    #expect(try ConstExprValue(optional).renderSource().contains("(7) as Swift.UInt8"))
    let custom = [ArrayRenderedNumber()]
    #expect(try ConstExprValue(custom).renderSource().contains("ArrayRenderedNumber(raw: (7) as Swift.UInt8)"))
    #expect(try custom.constExprExpression().description.contains("ArrayRenderedNumber(raw: (7) as Swift.UInt8)"))
}

@Test func nestedNumericArraysAndNonfiniteNumbersKeepNecessaryAnnotations() throws {
    #expect(try ConstExprValue([[UInt8(7)], []]).renderSource()
        == "([([7]) as Swift.Array<Swift.UInt8>, ([]) as Swift.Array<Swift.UInt8>]) as Swift.Array<Swift.Array<Swift.UInt8>>")
    let floats: [Float] = [.infinity, -.infinity, Float(bitPattern: 0x7fc0_0042)]
    let doubles: [Double] = [.infinity, -.infinity, Double(bitPattern: 0x7ff8_0000_0000_0042)]
    for source in [try ConstExprValue(floats).renderSource(), try floats.constExprExpression().description] {
        #expect(source.contains("Swift.Float.infinity, -Swift.Float.infinity"))
        #expect(source.contains("Swift.Float(bitPattern: \(floats[2].bitPattern))"))
    }
    for source in [try ConstExprValue(doubles).renderSource(), try doubles.constExprExpression().description] {
        #expect(source.contains("Swift.Double.infinity, -Swift.Double.infinity"))
        #expect(source.contains("Swift.Double(bitPattern: \(doubles[2].bitPattern))"))
    }
}
