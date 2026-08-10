import ConstExpr
import Testing

public struct DirectMemberFixture {
    public let value: Int

    @ConstExpr(registrationAccess: .package)
    public init(value: Int = 4) {
        self.value = value
    }

    @ConstExpr(registrationAccess: .package)
    public func adding(_ amount: Int) -> Int {
        value + amount
    }

    @ConstExpr(registrationAccess: .package)
    public var doubled: Int {
        value * 2
    }

    @ConstExpr(registrationAccess: .package)
    public subscript(index: Int) -> Int {
        value + index
    }
}

extension DirectMemberFixture {
    @ConstExpr(registrationAccess: .package)
    public static func make(_ value: Int) -> DirectMemberFixture {
        DirectMemberFixture(value: value)
    }
}

public enum DirectMemberOuterFixture {}

extension DirectMemberOuterFixture {
    public struct Nested {
        @ConstExpr(registrationAccess: .package)
        public static func answer() -> Int { 42 }
    }
}

public struct ManyLiteralDefaultsFixture {
    public let total: Int

    @ConstExpr(registrationAccess: .package)
    public init(
        a: Int = 1,
        b: Int = 2,
        c: Int = 3,
        d: Int = 4,
        e: Int = 5,
        f: Int = 6,
        g: Int = 7,
        h: Int = 8,
        i: Int = 9,
        j: Int = 10
    ) {
        total = a + b + c + d + e + f + g + h + i + j
    }

    @ConstExpr(registrationAccess: .package)
    public var value: Int { total }
}

public class FinalDirectClassMemberFixture {
    public let value: Int

    @ConstExpr(registrationAccess: .package)
    public init(value: Int) {
        self.value = value
    }

    @ConstExpr(registrationAccess: .package)
    public final func adding(_ amount: Int) -> Int { value + amount }

    @ConstExpr(registrationAccess: .package)
    public final var doubled: Int { value * 2 }

    @ConstExpr(registrationAccess: .package)
    public final subscript(index: Int) -> Int { value + index }
}

private let directMemberRegistry = #constExprRegistry(
    DirectMemberFixture.init(value:),
    DirectMemberFixture.adding(_:),
    \DirectMemberFixture.doubled,
    DirectMemberFixture.make(_:),
    DirectMemberFixture.subscript__constExpr(
        __constExprSelector_1_5_index: ((Int) -> Int).self
    ),
    DirectMemberOuterFixture.Nested.answer,
    ManyLiteralDefaultsFixture.init(a:b:c:d:e:f:g:h:i:j:),
    \ManyLiteralDefaultsFixture.value,
    FinalDirectClassMemberFixture.init(value:),
    FinalDirectClassMemberFixture.adding(_:),
    \FinalDirectClassMemberFixture.doubled,
    FinalDirectClassMemberFixture.subscript__constExpr(
        __constExprSelector_1_5_index: ((Int) -> Int).self
    )
)

@Test func directlyAnnotatedMembersCompileAndEvaluate() {
    let result = ConstExprRunner(registry: directMemberRegistry).rewrite(
        source: """
        let value = DirectMemberFixture(value: 5)
        let added = value.adding(3)
        let doubled = value.doubled
        let indexed = value[2]
        let made = DirectMemberFixture.make(8).doubled
        let nested = DirectMemberOuterFixture.Nested.answer()
        let defaults = ManyLiteralDefaultsFixture().value
        let classValue = FinalDirectClassMemberFixture(value: 6)
        let classAdded = classValue.adding(3)
        let classDoubled = classValue.doubled
        let classIndexed = classValue[4]
        """
    )

    #expect(result.diagnostics.isEmpty)
    #expect(result.source == """
        let value = DirectMemberFixture(value: 5)
        let added = 8
        let doubled = 10
        let indexed = 7
        let made = 16
        let nested = 42
        let defaults = 55
        let classValue = FinalDirectClassMemberFixture(value: 6)
        let classAdded = 9
        let classDoubled = 12
        let classIndexed = 10
        """)
}
