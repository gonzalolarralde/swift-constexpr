import Testing
@testable import ConstExpr

@Test func registrySharesOneLazilyBuiltIndexAcrossConcurrentReaders() async {
    let registry = ConstExprRegistry(
        ConstExprRegistration(
            name: "identity",
            kind: .function,
            parameterLabels: [nil],
            parameterTypes: [Int.self],
            resultType: Int.self
        ) { _, arguments in
            try #require(arguments[0])
        }
    )

    let identifiers = await withTaskGroup(
        of: ObjectIdentifier.self,
        returning: Set<ObjectIdentifier>.self
    ) { group in
        for _ in 0..<32 {
            group.addTask {
                ObjectIdentifier(registry.index)
            }
        }
        var identifiers: Set<ObjectIdentifier> = []
        for await identifier in group {
            identifiers.insert(identifier)
        }
        return identifiers
    }

    #expect(identifiers.count == 1)
    #expect(registry.registrations.count == 1)
    #expect(registry.candidates(named: "identity", kind: .function).count == 1)
}
