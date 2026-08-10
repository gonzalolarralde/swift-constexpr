import Foundation
import Testing
@testable import ConstExpr

private final class DeprecatedStoredPropertyCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    func increment() {
        lock.withLock { storage += 1 }
    }

    var value: Int {
        lock.withLock { storage }
    }
}

private let deprecatedStoredPropertyCounter = DeprecatedStoredPropertyCounter()

@ConstExpr
private struct DeprecatedStoredPropertyValue {
    let value: Int

    init(value: Int) {
        deprecatedStoredPropertyCounter.increment()
        self.value = value
    }

    @available(macOS, introduced: 11, deprecated: 99)
    static let legacy: Self = .init(value: 42)
}

private let deprecatedStoredPropertyRegistry = #constExprRegistry(
    DeprecatedStoredPropertyValue.self
)

@ConstExpr
private final class DeprecatedStoredSingleton: @unchecked Sendable {
    @available(macOS, introduced: 11, deprecated: 99)
    static let shared: DeprecatedStoredSingleton = .init()
}

private let deprecatedStoredSingletonRegistry = #constExprRegistry(
    DeprecatedStoredSingleton.self
)

@Test func copiedDeprecatedStoredInitializerHonorsItsAvailabilityBoundary() {
    let beforeDeprecation = ConstExprRunner(
        registry: deprecatedStoredPropertyRegistry,
        options: .init(availabilityContext: .init(versions: [
            "macOS": .init(major: 98),
        ]))
    ).evaluate(
        source: "let value: DeprecatedStoredPropertyValue = DeprecatedStoredPropertyValue.legacy",
        binding: "value",
        as: DeprecatedStoredPropertyValue.self
    )

    switch beforeDeprecation {
    case .success(let value):
        #expect(value.value == 42)
    case .fallback(let fallback):
        Issue.record("unexpected pre-deprecation fallback: \(fallback)")
    }
    #expect(deprecatedStoredPropertyCounter.value == 1)

    let atDeprecation = ConstExprRunner(
        registry: deprecatedStoredPropertyRegistry,
        options: .init(availabilityContext: .init(versions: [
            "macOS": .init(major: 99),
        ]))
    ).evaluateValue(
        source: "let value: DeprecatedStoredPropertyValue = DeprecatedStoredPropertyValue.legacy",
        binding: "value"
    )

    guard case .fallback = atDeprecation else {
        Issue.record("deprecated property unexpectedly evaluated")
        return
    }
    #expect(deprecatedStoredPropertyCounter.value == 1)
}

@Test func deprecatedClassSingletonIsNotCopiedIntoARegistration() {
    #expect(
        deprecatedStoredSingletonRegistry.candidates(
            named: "shared",
            kind: .staticProperty
        ).isEmpty
    )
}
