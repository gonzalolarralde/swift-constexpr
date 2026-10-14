import ConstExpr
import ConstExprEvaluation
import Testing

@Test func compactNumericArraysCompileWithExactTypesAndValues() throws {
    var checks: [String] = []
    func check<T: ConstExprRepresentable>(_ values: [T]) throws {
        let original = "[" + (try values.map { try $0.constExprExpression().description }).joined(separator: ", ") + "] as \(String(reflecting: [T].self))"
        for rendered in [try ConstExprValue(values).renderSource(), try values.constExprExpression().description] {
            checks.append("check(\(rendered), \(original))")
        }
    }
    try check([Int.min, Int.max])
    try check([Int8.min, Int8.max])
    try check([Int16.min, Int16.max])
    try check([Int32.min, Int32.max])
    try check([Int64.min, Int64.max])
    try check([UInt.min, UInt.max])
    try check([UInt8.min, UInt8.max])
    try check([UInt16.min, UInt16.max])
    try check([UInt32.min, UInt32.max])
    try check([UInt64.min, UInt64.max])
    try check([Float(-0.0), .leastNormalMagnitude, .greatestFiniteMagnitude])
    try check([Double(-0.0), .leastNormalMagnitude, .greatestFiniteMagnitude])
    try check([UInt8]())
    let erased = try ConstExprValue([UInt8(7), Int16(-2), Float(1.5)] as [Any]).renderSource()
    let floats = try ConstExprValue([Float(-0.0), Float(bitPattern: 0x7fc0_0042)]).renderSource()
    let doubles = try ConstExprValue([Double(-0.0), Double(bitPattern: 0x7ff8_0000_0000_0042)]).renderSource()
    let bytes = try ConstExprValue([UInt8(7)]).renderSource()
    let result = try compilerDifferentialRun(support: """
        func check<T: Equatable>(_ actual: [T], _ expected: [T]) {
            precondition(actual == expected)
        }
        func overload(_ bytes: [UInt8]) -> String { "bytes" }
        func overload(_ integers: [Int]) -> String { "integers" }
        """, source: checks.joined(separator: "\n") + """

        let bytes = \(bytes)
        precondition(overload(bytes) == "bytes")
        precondition(overload(\(bytes)) == "bytes")
        let erased = \(erased)
        precondition(type(of: erased[0]) == UInt8.self)
        precondition(type(of: erased[1]) == Int16.self)
        precondition(type(of: erased[2]) == Float.self)
        let floats = \(floats)
        precondition(floats[0].bitPattern == Float(-0.0).bitPattern)
        precondition(floats[1].bitPattern == 0x7fc0_0042)
        let doubles = \(doubles)
        precondition(doubles[0].bitPattern == Double(-0.0).bitPattern)
        precondition(doubles[1].bitPattern == 0x7ff8_0000_0000_0042)
        print("ok")
        """)
    #expect(result.status == 0, "\(result.error)")
    #expect(result.error.isEmpty)
    #expect(result.output == "ok\n")
}
