import Testing
@testable import ConstExpr

@Test func standardOperatorsRespectAssociativityParenthesesAndPrecedence() {
    let result = ConstExprRunner(registry: .empty).rewrite(source: """
        let subtraction = 20 - 5 - 3
        let parentheses = 2 * (3 + 4)
        let comparison = 2 + 2 == 4 && 3 < 5
        let bitwise = (6 & 3) | 8
        """)

    #expect(result.source == """
        let subtraction = 12
        let parentheses = 14
        let comparison = true
        let bitwise = 10
        """)
    #expect(result.diagnostics.isEmpty)
}

@Test func primitiveStringBooleanAndFloatingOperatorsFold() {
    let result = ConstExprRunner(registry: .empty).rewrite(source: """
        let string = "a" + "b"
        let ordering = "a" < "b"
        let boolean = !false && true
        let floating = 1.5 * 2.0
        let character = Character("a") < Character("b")
        """)

    #expect(result.source == """
        let string = "ab"
        let ordering = true
        let boolean = true
        let floating = 3.0
        let character = true
        """)
}

@Test func contextualPrefixAndStructuralOperatorsFold() {
    let result = ConstExprRunner(registry: .empty).rewrite(source: """
        let plusFloat: Float = +(1.5 as Float)
        let minusFloat: Float = -(1.5 as Float)
        let multipliedFloat: Float = (1.5 as Float) * (2.0 as Float)
        let plusDouble: Double = +(1.5 as Double)
        let minusDouble: Double = -(1.5 as Double)
        let plusInt8: Int8 = +(1 as Int8)
        let minusInt8: Int8 = -(1 as Int8)
        let inverted: UInt8 = ~(1 as UInt8)
        let inverted16: UInt16 = ~(1 as UInt16)
        let inverted32: UInt32 = ~(1 as UInt32)
        let inverted64: UInt64 = ~(1 as UInt64)
        let concatenated: [Int] = [1] + [2, 3]
        let inferredConcatenated = [1] + [2]
        let first: Int? = 1
        let second: Int? = 1
        let none: Int? = nil
        let optionalsEqual = first == second
        let optionalsUnequal = first != none
        let arraysEqual = [1, 2] == [1, 2]
        let arraysUnequal = [1, 2] != [1, 3]
        let dictionariesEqual = ["one": 1] == ["one": 1]
        let dictionariesUnequal = ["one": 1] != ["one": 2]
        let dictionariesIgnoreOrder = ["one": 1, "two": 2] == ["two": 2, "one": 1]
        let dictionariesCompareKeys = ["one": 1] == ["two": 1]
        let tuplesEqual = (1, "one") == (1, "one")
        let tuplesUnequal = (1, "one") != (2, "one")
        let noFirst: Int? = nil
        let noSecond: Int? = nil
        let nilOptionalsEqual = noFirst == noSecond
        """)

    #expect(result.source == """
        let plusFloat: Float = (1.5) as Swift.Float
        let minusFloat: Float = (-1.5) as Swift.Float
        let multipliedFloat: Float = (3.0) as Swift.Float
        let plusDouble: Double = 1.5
        let minusDouble: Double = -1.5
        let plusInt8: Int8 = (1) as Swift.Int8
        let minusInt8: Int8 = (-1) as Swift.Int8
        let inverted: UInt8 = (254) as Swift.UInt8
        let inverted16: UInt16 = (65534) as Swift.UInt16
        let inverted32: UInt32 = (4294967294) as Swift.UInt32
        let inverted64: UInt64 = (18446744073709551614) as Swift.UInt64
        let concatenated: [Int] = ([1, 2, 3]) as [Int]
        let inferredConcatenated = ([1, 2]) as [Int]
        let first: Int? = (1) as Int?
        let second: Int? = (1) as Int?
        let none: Int? = nil as Int?
        let optionalsEqual = true
        let optionalsUnequal = true
        let arraysEqual = true
        let arraysUnequal = true
        let dictionariesEqual = true
        let dictionariesUnequal = true
        let dictionariesIgnoreOrder = true
        let dictionariesCompareKeys = false
        let tuplesEqual = true
        let tuplesUnequal = true
        let noFirst: Int? = nil as Int?
        let noSecond: Int? = nil as Int?
        let nilOptionalsEqual = true
        """)
    #expect(result.diagnostics.isEmpty)
}

@Test func erasedStructuralEqualityNeverRepairsInvalidSwift() {
    let source = """
        let dictionary = (["one": 1] as [String: Any]) == (["one": 1] as [String: Any])
        let tuple = (1 as Any, 2) != (1 as Any, 2)
        let emptyArray = ([] as [Any]) == ([] as [Any])
        let emptyDictionary = ([:] as [String: Any]) != ([:] as [String: Any])
        let heterogeneousNil = (nil as Int?) == (nil as String?)
        let heterogeneousSome = (1 as Int?) != ("1" as String?)
        let first: Any? = nil
        let second: Any? = nil
        let optional = first == second
        """
    let result = ConstExprRunner(registry: .empty).rewrite(source: source)

    #expect(result.source.contains("dictionary ="))
    #expect(result.source.contains("[String: Any]) =="))
    #expect(result.source.contains("tuple ="))
    #expect(result.source.contains("!= ("))
    #expect(result.source.contains("emptyArray ="))
    #expect(result.source.contains("emptyDictionary ="))
    #expect(result.source.contains("optional ="))
    #expect(result.source.contains("nil as Any?) == (nil as Any?"))
    #expect(!result.source.contains("dictionary = true"))
    #expect(!result.source.contains("dictionary = false"))
    #expect(!result.source.contains("tuple = true"))
    #expect(!result.source.contains("tuple = false"))
    #expect(!result.source.contains("emptyArray = true"))
    #expect(!result.source.contains("emptyArray = false"))
    #expect(!result.source.contains("emptyDictionary = true"))
    #expect(!result.source.contains("emptyDictionary = false"))
    #expect(result.source.contains("heterogeneousNil ="))
    #expect(result.source.contains("Int?) == (nil as String?"))
    #expect(result.source.contains("heterogeneousSome ="))
    #expect(result.source.contains("Int?) != ((\"1\") as String?"))
    #expect(!result.source.contains("heterogeneousNil = true"))
    #expect(!result.source.contains("heterogeneousNil = false"))
    #expect(!result.source.contains("heterogeneousSome = true"))
    #expect(!result.source.contains("heterogeneousSome = false"))
    #expect(!result.source.contains("optional = true"))
    #expect(!result.source.contains("optional = false"))
    #expect(result.diagnostics.isEmpty)

    #expect(
        ConstExprOperators.valuesEqual(
            ConstExprValue([Int]()),
            ConstExprValue([Int]())
        ) == true
    )
    #expect(
        ConstExprOperators.valuesEqual(
            ConstExprValue([Any]()),
            ConstExprValue([Any]())
        ) == nil
    )
    #expect(
        ConstExprOperators.valuesEqual(
            ConstExprValue([String: Int]()),
            ConstExprValue([String: Int]())
        ) == true
    )
    #expect(
        ConstExprOperators.valuesEqual(
            ConstExprValue([String: Any]()),
            ConstExprValue([String: Any]())
        ) == nil
    )
}

@Test func integerTrapsAreDiagnosedWhileSwiftShiftSemanticsArePreserved() {
    let result = ConstExprRunner(registry: .empty).rewrite(source: """
        let division = 10 / 0
        let remainder = 10 % 0
        let shift = 1 << 64
        let overflow = 9_223_372_036_854_775_807 + 1
        """)

    #expect(result.source == """
        let division = 10 / 0
        let remainder = 10 % 0
        let shift = 0
        let overflow = 9_223_372_036_854_775_807 + 1
        """)
    #expect(result.diagnostics.map(\.code) == [
        "division-by-zero",
        "division-by-zero",
        "integer-overflow",
    ])
}

@Test func shiftsAcceptNegativeAndOversizedCountsLikeSwift() {
    let result = ConstExprRunner(registry: .empty).rewrite(source: """
        let reversed = 4 << -1
        let oversized = 1 << 64
        let signed = -4 >> 64
        """)

    #expect(result.source == """
        let reversed = 2
        let oversized = 0
        let signed = -1
        """)
    #expect(result.diagnostics.isEmpty)
}

@Test func fixedWidthShiftResultsAcceptIndependentIntegerCountTypes() {
    let result = ConstExprRunner(registry: .empty).rewrite(source: """
        let oversized: UInt8 = 1 << 256
        let reversed: UInt8 = 1 << -1
        let mixed: UInt16 = 1 << (2 as UInt8)
        let signed: Int8 = -4 >> (64 as UInt64)
        """)

    #expect(result.source == """
        let oversized: UInt8 = (0) as Swift.UInt8
        let reversed: UInt8 = (0) as Swift.UInt8
        let mixed: UInt16 = (4) as Swift.UInt16
        let signed: Int8 = (-1) as Swift.Int8
        """)
    #expect(result.diagnostics.isEmpty)
}

@Test func fixedWidthLiteralBoundariesRadicesAndWrappingAreExact() {
    let result = ConstExprRunner(registry: .empty).rewrite(source: """
        let minimum: Int8 = -0x80
        let hexadecimal: UInt8 = 0xff
        let binary: UInt16 = 0b1010_1010
        let maximum: UInt64 = 18_446_744_073_709_551_615
        let wrapped: UInt8 = 0xff &+ 2
        let overflow: Int8 = 0x7f + 1
        let trappingConversion = Int8(0xff &+ 1)
        """)

    #expect(result.source == """
        let minimum: Int8 = (-128) as Swift.Int8
        let hexadecimal: UInt8 = (255) as Swift.UInt8
        let binary: UInt16 = (170) as Swift.UInt16
        let maximum: UInt64 = (18446744073709551615) as Swift.UInt64
        let wrapped: UInt8 = (1) as Swift.UInt8
        let overflow: Int8 = 0x7f + 1
        let trappingConversion = Int8(256)
        """)
    #expect(result.diagnostics.map(\.code) == ["integer-overflow"])
}

@Test func unknownParentsOnlyReceiveContextIndependentOperatorResults() {
    let result = ConstExprRunner(registry: .empty).rewrite(
        source: "let result = unknown(1 + 2, false || true)"
    )

    // An unknown parameter may contextually type `1 + 2` as any integer or
    // floating-point type. Boolean operators have only one possible type and
    // remain safe to simplify.
    #expect(result.source == "let result = unknown(1 + 2, true)")
}
