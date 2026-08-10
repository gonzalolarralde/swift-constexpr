import ConstExpr
import Testing

private final class ThrowingSyntaxCounter: @unchecked Sendable {
    var value = 0
}

private let throwingSyntaxCounter = ThrowingSyntaxCounter()
private let manualThrowingSyntaxCounter = ThrowingSyntaxCounter()

private enum GeneratedThrowingFixtureError: Error {
    case rejected
}

@ConstExpr
private func differentialThrowingValue(_ succeeds: Bool) throws -> Int {
    throwingSyntaxCounter.value += 1
    if !succeeds {
        struct ExpectedFailure: Error {}
        throw ExpectedFailure()
    }
    return 7
}

private let throwingSyntaxRegistry = #constExprRegistry(
    differentialThrowingValue(_:)
)

@ConstExpr
private final class GeneratedThrowingFixture {
    let value: Int

    init(_ value: Int) throws {
        guard value >= 0 else { throw GeneratedThrowingFixtureError.rejected }
        self.value = value
    }

    func doubled() throws -> Int {
        guard value >= 0 else { throw GeneratedThrowingFixtureError.rejected }
        return value * 2
    }

    static func fixed() throws -> Int {
        11
    }
}

private let generatedThrowingFixtureRegistry = #constExprRegistry(
    GeneratedThrowingFixture.self
)

@Test func generatedThrowingRegistrationsRequireTryAtTheSourceCallSite() {
    #expect(throwingSyntaxRegistry.registrations.first?.isThrowing == true)
    throwingSyntaxCounter.value = 0
    let result = ConstExprRunner(registry: throwingSyntaxRegistry).rewrite(source: """
        let missingTry = differentialThrowingValue(true)
        let explicitTry = try differentialThrowingValue(true)
        """)

    #expect(result.source == """
        let missingTry = differentialThrowingValue(true)
        let explicitTry = 7
        """)
    #expect(throwingSyntaxCounter.value == 1)
}

@Test func generatedThrowingNominalRegistrationsExposeAndHonorEffects() throws {
    let initializer = try #require(
        generatedThrowingFixtureRegistry.registrations.first {
            $0.kind == .initializer
        }
    )
    let instanceMethod = try #require(
        generatedThrowingFixtureRegistry.registrations.first {
            $0.kind == .instanceMethod && $0.name == "doubled"
        }
    )
    let staticMethod = try #require(
        generatedThrowingFixtureRegistry.registrations.first {
            $0.kind == .staticMethod && $0.name == "fixed"
        }
    )
    let property = try #require(
        generatedThrowingFixtureRegistry.registrations.first {
            $0.kind == .instanceProperty && $0.name == "value"
        }
    )

    #expect(initializer.isThrowing)
    #expect(instanceMethod.isThrowing)
    #expect(staticMethod.isThrowing)
    #expect(!property.isThrowing)

    let instance = try initializer.invoke(arguments: [ConstExprValue(3)])
    #expect(try instanceMethod.invoke(receiver: instance).require(Int.self) == 6)
    #expect(try staticMethod.invoke().require(Int.self) == 11)
    #expect(try property.invoke(receiver: instance).require(Int.self) == 3)
}

@Test func outerTryDoesNotCrossClosureBoundariesOrEraseInferredEffects() {
    manualThrowingSyntaxCounter.value = 0
    let registry = ConstExprRegistry(
        ConstExprRegistration(
            name: "manualThrowingValue",
            kind: .function,
            resultType: Int.self,
            isThrowing: true
        ) { _, _ in
            manualThrowingSyntaxCounter.value += 1
            return ConstExprValue(7)
        }
    )
    let source = """
        func consumeThrowingClosure(
            _ body: () throws -> Int
        ) rethrows -> Int {
            try body()
        }
        let missingInnerTry = try consumeThrowingClosure {
            manualThrowingValue()
        }
        let explicitInnerTry = try consumeThrowingClosure {
            try manualThrowingValue()
        }
        """

    let result = ConstExprRunner(registry: registry).rewrite(source: source)

    #expect(result.source == source)
    #expect(manualThrowingSyntaxCounter.value == 0)
}
