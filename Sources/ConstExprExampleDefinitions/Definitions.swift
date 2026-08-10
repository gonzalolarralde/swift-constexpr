import ConstExpr

@ConstExpr
public func foo(_ value: Int) -> Int {
    value + 1
}

@ConstExpr
public func describe(prefix: String = "value", number: Int) -> String {
    "\(prefix): \(number)"
}

@ConstExpr
public func transform(_ value: Int) -> String {
    "int:\(value)"
}

@ConstExpr
public func transform(_ value: String) -> String {
    "string:\(value)"
}

@ConstExpr
public func total(_ values: [Int]) -> Int {
    values.reduce(0, +)
}

@ConstExpr
public func dictionarySummary(_ values: [String: Int]) -> String {
    values.keys.sorted().map { "\($0)=\(values[$0]!)" }.joined(separator: ",")
}

@ConstExpr
public func route(x value: Int) -> String {
    "x:\(value)"
}

@ConstExpr
public func route(y value: Int) -> String {
    "y:\(value)"
}

@ConstExpr
public func int64Value() -> Int64 {
    5
}

@ConstExpr
public func floatValue() -> Float {
    1.5
}

@ConstExpr
public func characterValue() -> Character {
    "x"
}

@ConstExpr
public func optionalValue(_ present: Bool) -> Int? {
    present ? 5 : nil
}

@ConstExpr
public func acceptsInt64(_ value: Int64) -> String {
    "int64:\(value)"
}

@ConstExpr
public func acceptsFloat(_ value: Float) -> String {
    "float:\(value)"
}

@ConstExpr
public func acceptsCharacter(_ value: Character) -> String {
    "character:\(value)"
}

@ConstExpr
public func typedValue() -> Int {
    7
}

@ConstExpr
public func typedValue() -> String {
    "seven"
}

public enum ExampleFailure: Error {
    case expected
}

@ConstExpr
public func throwingValue(_ succeeds: Bool) throws -> String {
    guard succeeds else { throw ExampleFailure.expected }
    return "success"
}

@ConstExpr
public let exampleAnswer = 42

@ConstExpr
public struct Bar {
    private let value: Int

    public init(_ value: Int) {
        self.value = value
    }

    public func build() -> String {
        "Bar \(value)"
    }

    func internalVisibilityFixture() -> Int {
        value
    }

    @_spi(Secret)
    public func spiVisibilityFixture() -> Int {
        value
    }
}

@ConstExpr
public struct ChainLeaf {
    public init() {}

    public func blah() -> String {
        "5"
    }
}

@ConstExpr
public struct Foo {
    public init() {}

    public static var answer: Int { 42 }

    public static func makeLeaf() -> ChainLeaf {
        ChainLeaf()
    }

    public var bar: ChainLeaf {
        ChainLeaf()
    }
}

@ConstExpr
public struct FailableValue {
    private let value: Int

    public init?(_ value: Int) {
        guard value >= 0 else { return nil }
        self.value = value
    }

    public func rendered() -> String {
        "value:\(value)"
    }
}

@ConstExpr
public enum ExampleStatus {
    case code(Int)

    public func message() -> String {
        switch self {
        case .code(let value): "code:\(value)"
        }
    }
}

@ConstExpr
public final class ExampleBox {
    private let value: String

    public init(_ value: String) {
        self.value = value
    }

    public subscript(index: Int) -> Character {
        value[value.index(value.startIndex, offsetBy: index)]
    }

    public func uppercased() -> String {
        value.uppercased()
    }
}
