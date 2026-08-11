import ConstExpr
import Testing

@ConstExpr
private struct NamedExtensionRegistryFixture {
    let value: Int

    init(value: Int) {
        self.value = value
    }

    func doubled() -> Int { value * 2 }
}

@ConstExprMembers(named: "Networking")
private extension NamedExtensionRegistryFixture {
    static func endpoint(port: Int) -> String { "localhost:\(port)" }

    @ConstExprIgnored
    static func processDependentEndpoint() -> String {
        fatalError("must never execute")
    }

    static func unsupportedGeneric<T>(_ value: T) -> T { value }
}

private let namedExtensionRegistry = #constExprRegistry(
    for: NamedExtensionRegistryFixture.self,
    extensions: ["Networking"]
)

@Test func namedExtensionProviderCompilesAndEvaluates() {
    let result = ConstExprRunner(registry: namedExtensionRegistry).rewrite(
        source: """
        let value = NamedExtensionRegistryFixture(value: 6).doubled()
        let endpoint = NamedExtensionRegistryFixture.endpoint(port: 8080)
        """
    )

    #expect(result.diagnostics.isEmpty)
    #expect(result.source == """
        let value = 12
        let endpoint = "localhost:8080"
        """)
}
