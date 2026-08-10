import SwiftSyntax
import Testing
@testable import ConstExpr

class OptionalBaseValue {}
final class OptionalDerivedValue: OptionalBaseValue {}
struct OpaqueCollectionValue: Equatable {
    let id: Int
}

protocol ErasedRepresentableValue {}

struct ProtocolRepresentableValue: ErasedRepresentableValue, ConstExprRepresentable {
    func constExprExpression() throws -> ExprSyntax {
        "ProtocolRepresentableValue()"
    }
}

class ErasedRepresentableBase: ConstExprRepresentable {
    func constExprExpression() throws -> ExprSyntax {
        "ErasedRepresentableBase()"
    }
}

final class ErasedRepresentableDerived: ErasedRepresentableBase {
    override func constExprExpression() throws -> ExprSyntax {
        "ErasedRepresentableDerived()"
    }
}

protocol PrivateStructuralProtocol {}

struct PrivateStructuralValue: PrivateStructuralProtocol, ConstExprRepresentable {
    func constExprExpression() throws -> ExprSyntax {
        "PrivateStructuralValue()"
    }
}

class PrivateStructuralBase: ConstExprRepresentable {
    func constExprExpression() throws -> ExprSyntax {
        "PrivateStructuralBase()"
    }
}

final class PrivateStructuralDerived: PrivateStructuralBase {
    override func constExprExpression() throws -> ExprSyntax {
        "PrivateStructuralDerived()"
    }
}

@Test func valueAllFixedWidthIntegersRenderWithTheirStaticTypes() throws {
    #expect(try ConstExprValue(Int.min).renderSource() == String(Int.min))
    #expect(try ConstExprValue(Int8(-8)).renderSource() == "(-8) as Swift.Int8")
    #expect(try ConstExprValue(Int16(-16)).renderSource() == "(-16) as Swift.Int16")
    #expect(try ConstExprValue(Int32(-32)).renderSource() == "(-32) as Swift.Int32")
    #expect(try ConstExprValue(Int64(-64)).renderSource() == "(-64) as Swift.Int64")
    #expect(try ConstExprValue(UInt(1)).renderSource() == "(1) as Swift.UInt")
    #expect(try ConstExprValue(UInt8(8)).renderSource() == "(8) as Swift.UInt8")
    #expect(try ConstExprValue(UInt16(16)).renderSource() == "(16) as Swift.UInt16")
    #expect(try ConstExprValue(UInt32(32)).renderSource() == "(32) as Swift.UInt32")
    #expect(try ConstExprValue(UInt64.max).renderSource() == "(18446744073709551615) as Swift.UInt64")

    #expect(try ConstExprValue(Int8(-8)).require(Int8.self) == -8)
    #expect(try ConstExprValue(Int16(-16)).require(Int16.self) == -16)
    #expect(try ConstExprValue(Int32(-32)).require(Int32.self) == -32)
    #expect(try ConstExprValue(Int64(-64)).require(Int64.self) == -64)
    #expect(try ConstExprValue(UInt(1)).require(UInt.self) == 1)
    #expect(try ConstExprValue(UInt8(8)).require(UInt8.self) == 8)
    #expect(try ConstExprValue(UInt16(16)).require(UInt16.self) == 16)
    #expect(try ConstExprValue(UInt32(32)).require(UInt32.self) == 32)
    #expect(try ConstExprValue(UInt64.max).require(UInt64.self) == .max)
}

@Test func valueFloatingBooleanStringAndCharacterRenderingIsSourceSafe() throws {
    #expect(try ConstExprValue(Double(1.5)).renderSource() == "1.5")
    #expect(try ConstExprValue(Double.infinity).renderSource() == "Swift.Double.infinity")
    #expect(try ConstExprValue(-Double.infinity).renderSource() == "-Swift.Double.infinity")
    #expect(
        try ConstExprValue(Double.nan).renderSource()
            == "Swift.Double(bitPattern: \(Double.nan.bitPattern))"
    )
    #expect(try ConstExprValue(Float(1.5)).renderSource() == "(1.5) as Swift.Float")
    #expect(try ConstExprValue(Float.infinity).renderSource() == "Swift.Float.infinity")
    #expect(try ConstExprValue(true).renderSource() == "true")
    #expect(try ConstExprValue(false).renderSource() == "false")
    #expect(try ConstExprValue("a\n\"\\\0").renderSource() == "\"a\\n\\\"\\\\\\0\"")
    #expect(try ConstExprValue(Character("é")).renderSource() == "(\"é\") as Swift.Character")

    #expect(try ConstExprValue(Float(2.25)).require(Float.self) == 2.25)
    #expect(try ConstExprValue(Double(2.25)).require(Double.self) == 2.25)
    #expect(try ConstExprValue(true).require(Bool.self))
    #expect(try ConstExprValue("hello").require(String.self) == "hello")
    #expect(try ConstExprValue(Character("x")).require(Character.self) == "x")
}

@Test func valueFloatingNaNRenderingPreservesPayloadBits() throws {
    let double = Double(bitPattern: 0x7ff8_0000_0000_0042)
    let float = Float(bitPattern: 0x7fc0_0042)

    #expect(
        try ConstExprValue(double).renderSource()
            == "Swift.Double(bitPattern: \(double.bitPattern))"
    )
    #expect(
        try ConstExprValue(float).renderSource()
            == "Swift.Float(bitPattern: \(float.bitPattern))"
    )
}

@Test func valueRenderingPreservesExplicitErasureAndExistentialTypes() throws {
    let erasedInteger = ConstExprValue(7 as Any, preservingStaticType: Any.self)
    #expect(try erasedInteger.renderSource() == "(7) as Any")

    let erasedOptional: Any = Optional<Int>.none as Any
    let optionalValue = ConstExprValue(erasedOptional, preservingStaticType: Any.self)
    #expect(optionalValue.kind == .opaque)
    #expect(try optionalValue.renderSource() == "(nil as Swift.Optional<Swift.Int>) as Any")

    let existential: any ErasedRepresentableValue = ProtocolRepresentableValue()
    let existentialValue = ConstExprValue(
        existential as Any,
        preservingStaticType: (any ErasedRepresentableValue).self
    )
    #expect(existentialValue.kind == .opaque)
    let existentialSource = try existentialValue.renderSource()
    #expect(
        existentialSource
            == "(ProtocolRepresentableValue()) as any ConstExprRuntimeTests.ErasedRepresentableValue"
    )

    let inconsistent = ConstExprValue(
        "not an array" as Any,
        preservingStaticType: [Int].self
    )
    #expect(inconsistent.kind == .opaque)
    #expect(ObjectIdentifier(inconsistent.staticType) == ObjectIdentifier(String.self))
    #expect(inconsistent.renderedSource == "\"not an array\"")

    let derived = ErasedRepresentableDerived()
    let upcast = ConstExprValue(
        derived as Any,
        preservingStaticType: ErasedRepresentableBase.self
    )
    #expect(
        try upcast.renderSource()
            == "(ErasedRepresentableDerived()) as ConstExprRuntimeTests.ErasedRepresentableBase"
    )
    let objectErasure = ConstExprValue(
        derived as Any,
        preservingStaticType: AnyObject.self
    )
    #expect(try objectErasure.renderSource() == "(ErasedRepresentableDerived()) as AnyObject")
}

@Test func valueLiteralConversionsRequireLiteralProvenance() throws {
    let integer = ConstExprValue.integerLiteral(7)
    #expect(integer.literalKind == .integer)
    #expect(try integer.require(Int64.self) == 7)
    #expect(try integer.require(UInt8.self) == 7)
    #expect(try integer.require(Double.self) == 7)
    #expect(integer.literalConverted(to: Int16.self)?.staticType == Int16.self)

    #expect(throws: (any Error).self) {
        try ConstExprValue(7).require(Int64.self)
    }
    #expect(throws: (any Error).self) {
        try ConstExprValue.integerLiteral(-1).require(UInt.self)
    }

    let floating = ConstExprValue.floatingPointLiteral(1.25)
    #expect(floating.literalKind == .floatingPoint)
    #expect(try floating.require(Float.self) == 1.25)
    #expect(throws: (any Error).self) {
        try ConstExprValue(1.25).require(Float.self)
    }

    #expect(try ConstExprValue.stringLiteral("x").require(Character.self) == "x")
    #expect(throws: (any Error).self) {
        try ConstExprValue("x").require(Character.self)
    }
    #expect(throws: (any Error).self) {
        try ConstExprValue.stringLiteral("xy").require(Character.self)
    }
    #expect(ConstExprValue.booleanLiteral(true).literalKind == .boolean)
}

@Test func valueStructuralCastsProvideContextForPrivateAndExistentialChildren() throws {
    let existential: any PrivateStructuralProtocol = PrivateStructuralValue()
    let optional: (any PrivateStructuralProtocol)? = existential
    let optionalValue = ConstExprValue(
        optional as Any,
        preservingStaticType: (any PrivateStructuralProtocol)?.self,
        sourceTypeName: "(any PrivateStructuralProtocol)?"
    )
    #expect(
        try optionalValue.renderSource()
            == "(PrivateStructuralValue()) as (any PrivateStructuralProtocol)?"
    )

    let array: [any PrivateStructuralProtocol] = [existential]
    let arrayValue = ConstExprValue(
        array as Any,
        preservingStaticType: [any PrivateStructuralProtocol].self,
        sourceTypeName: "[any PrivateStructuralProtocol]"
    )
    #expect(
        try arrayValue.renderSource()
            == "([PrivateStructuralValue()]) as [any PrivateStructuralProtocol]"
    )

    let dictionary: [String: any PrivateStructuralProtocol] = ["value": existential]
    let dictionaryValue = ConstExprValue(
        dictionary as Any,
        preservingStaticType: [String: any PrivateStructuralProtocol].self,
        sourceTypeName: "[String: any PrivateStructuralProtocol]"
    )
    #expect(
        try dictionaryValue.renderSource()
            == "([\"value\": PrivateStructuralValue()]) as [String: any PrivateStructuralProtocol]"
    )

    let baseOptional: PrivateStructuralBase? = PrivateStructuralDerived()
    let baseOptionalValue = ConstExprValue(
        baseOptional as Any,
        preservingStaticType: PrivateStructuralBase?.self,
        sourceTypeName: "PrivateStructuralBase?"
    )
    #expect(
        try baseOptionalValue.renderSource()
            == "(PrivateStructuralDerived()) as PrivateStructuralBase?"
    )
}

@Test func valueTypedAndLiteralOptionalsRoundTrip() throws {
    let some = ConstExprValue(Optional<Int>.some(5))
    #expect(some.kind == .optional)
    #expect(some.isOptional)
    #expect(!some.isNil)
    #expect(try some.wrappedValue?.require(Int.self) == 5)
    #expect(try some.renderSource() == "(5) as Swift.Optional<Swift.Int>")
    #expect(try some.require(Int?.self) == 5)

    let none = ConstExprValue(Optional<Int>.none)
    #expect(none.isOptional)
    #expect(none.isNil)
    #expect(none.wrappedValue == nil)
    #expect(try none.renderSource() == "nil as Swift.Optional<Swift.Int>")
    let decodedNone = try none.require(Int?.self)
    #expect(decodedNone == nil)

    let literal = ConstExprValue.nilLiteral()
    #expect(literal.literalKind == .nilLiteral)
    #expect(literal.isNil)
    #expect(try literal.renderSource() == "nil")
    let decodedLiteral = try literal.require(String?.self)
    #expect(decodedLiteral == nil)

    let dynamicallyTypedNone = ConstExprValue.optional(nil, wrappedType: String.self)
    #expect(ObjectIdentifier(dynamicallyTypedNone.staticType) == ObjectIdentifier(String?.self))
    #expect(dynamicallyTypedNone.optionalWraps(String.self))
    #expect(
        dynamicallyTypedNone.optionalWrappedType.map { ObjectIdentifier($0) }
            == ObjectIdentifier(String.self)
    )
    #expect(try dynamicallyTypedNone.renderSource() == "nil as Swift.Optional<Swift.String>")
    let dynamicallyTypedSome = ConstExprValue.optional(.init("value"), wrappedType: String.self)
    #expect(try dynamicallyTypedSome.require(String?.self) == "value")
    #expect(
        try dynamicallyTypedSome.renderSource()
            == "(\"value\") as Swift.Optional<Swift.String>"
    )

    let nested: Int?? = .some(nil)
    let nestedValue = ConstExprValue(nested)
    #expect(nestedValue.wrappedValue?.isNil == true)
    #expect(try nestedValue.require(Int??.self) == nested)

    let injected = try ConstExprValue.integerLiteral(9).require(Int64?.self)
    #expect(injected == 9)
    let doublyInjected = try ConstExprValue.integerLiteral(9).require(Int64??.self)
    #expect(doublyInjected == 9)
}

@Test func valueOptionalsPreserveStaticWrappedClassTypes() throws {
    let source: OptionalBaseValue? = OptionalDerivedValue()
    let value = ConstExprValue(source)
    let wrapped = try #require(value.wrappedValue)

    #expect(ObjectIdentifier(wrapped.staticType) == ObjectIdentifier(OptionalBaseValue.self))
    #expect(try wrapped.require(OptionalBaseValue.self) is OptionalDerivedValue)
    #expect(value.optionalWraps(OptionalBaseValue.self))
}

@Test func valueCollectionsPreserveStaticClassElementTypes() throws {
    let arraySource: [OptionalBaseValue] = [OptionalDerivedValue()]
    let array = ConstExprValue(arraySource)
    let element = try #require(array.arrayElements?.first)
    #expect(ObjectIdentifier(element.staticType) == ObjectIdentifier(OptionalBaseValue.self))
    #expect(try element.require(OptionalBaseValue.self) is OptionalDerivedValue)

    let dictionarySource: [String: OptionalBaseValue] = ["value": OptionalDerivedValue()]
    let dictionary = ConstExprValue(dictionarySource)
    let entry = try #require(dictionary.dictionaryEntries?.first)
    #expect(ObjectIdentifier(entry.key.staticType) == ObjectIdentifier(String.self))
    #expect(ObjectIdentifier(entry.value.staticType) == ObjectIdentifier(OptionalBaseValue.self))
    #expect(try entry.value.require(OptionalBaseValue.self) is OptionalDerivedValue)
}

@Test func valueDynamicClassTypesDoNotBecomeImplicitConversions() throws {
    let source: OptionalBaseValue = OptionalDerivedValue()
    let value = ConstExprValue(source)

    #expect(ObjectIdentifier(value.staticType) == ObjectIdentifier(OptionalBaseValue.self))
    #expect(!value.canDecode(OptionalDerivedValue.self))
    #expect(value.cast(to: OptionalDerivedValue.self) != nil)

    let staticallyDerived = ConstExprValue(OptionalDerivedValue())
    #expect(staticallyDerived.canDecode(OptionalBaseValue.self))
    #expect(staticallyDerived.canDecode(AnyObject.self))
    #expect(staticallyDerived.canDecode(Any.self))
    #expect(try staticallyDerived.require(OptionalBaseValue.self) is OptionalDerivedValue)
}

@Test func valueStructuralContainersDecodeOpaqueCustomElements() throws {
    let first = ConstExprValue(OpaqueCollectionValue(id: 1))
    let second = ConstExprValue(OpaqueCollectionValue(id: 2))

    let array = ConstExprValue.array([first, second])
    #expect(try array.require([OpaqueCollectionValue].self) == [
        OpaqueCollectionValue(id: 1),
        OpaqueCollectionValue(id: 2),
    ])
    #expect(array.canDecode([OpaqueCollectionValue].self))

    let dictionary = ConstExprValue.dictionary([
        (.stringLiteral("first"), first),
        (.stringLiteral("second"), second),
    ])
    #expect(try dictionary.require([String: OpaqueCollectionValue].self) == [
        "first": OpaqueCollectionValue(id: 1),
        "second": OpaqueCollectionValue(id: 2),
    ])
    #expect(dictionary.canDecode([String: OpaqueCollectionValue].self))

    #expect(try first.require(OpaqueCollectionValue?.self) == OpaqueCollectionValue(id: 1))
    #expect(first.canDecode(OpaqueCollectionValue?.self))
}

@Test func valueArraysDecodeRecursivelyAndPreserveBoxedStaticType() throws {
    let structural = ConstExprValue.array([
        .array([.integerLiteral(1), .integerLiteral(2)]),
        .array([.integerLiteral(3)]),
    ])
    #expect(structural.kind == .array)
    #expect(structural.arrayElements?.count == 2)
    #expect(try structural.require([[Int]].self) == [[1, 2], [3]])
    #expect(try structural.renderSource() == "[[1, 2], [3]]")

    let typed = try ConstExprValue.array(
        [.integerLiteral(1), .integerLiteral(2)],
        as: [Int64].self
    )
    #expect(ObjectIdentifier(typed.staticType) == ObjectIdentifier([Int64].self))
    #expect(try typed.require([Int64].self) == [1, 2])
    #expect(
        try typed.renderSource()
            == "([(1) as Swift.Int64, (2) as Swift.Int64]) as Swift.Array<Swift.Int64>"
    )

    let boxed = ConstExprValue([Int8(1), Int8(2)])
    #expect(ObjectIdentifier(boxed.staticType) == ObjectIdentifier([Int8].self))
    #expect(try boxed.require([Int8].self) == [1, 2])
}
