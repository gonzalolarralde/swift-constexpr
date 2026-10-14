import ConstExprRegistryGeneration
import Testing

@Test(arguments: [
    ("@ConstExpr struct Hidden {}", "not visible"),
    ("struct Hidden { @ConstExpr public struct Nested {} }", "enclosing type"),
    ("@ConstExpr public func generic<T>(_ value: T) -> T { value }", "no selectable"),
    ("@ConstExpr public var mutable = 7", "immutable global"),
    ("@ConstExpr public func broken( {", "error:"),
    ("#if FEATURE\n@ConstExpr public enum Conditional {}\n#endif", "conditional ConstExpr"),
    ("@ConstExpr public struct Conditional {\n#if FEATURE\npublic func value() -> Int { 1 }\n#endif\n}", "conditional members"),
    ("@available(macOS 15, *) @ConstExpr public enum Recent {}", "availability- or SPI-gated"),
    ("@ConstExprMembers(named: \"Missing\", registrationAccess: .package) public extension Owner {}", "requires an @ConstExpr root"),
    ("#if canImport(Foundation)\nimport Foundation\n#endif\n@ConstExpr public enum Conditional {}", "conditional imports"),
])
func unsupportedDiscoveryReportsActionableErrors(source: String, message: String) {
    do {
        _ = try generatedRegistry(source)
        Issue.record("expected discovery to reject: \(source)")
    } catch {
        #expect(String(describing: error).contains(message), "\(error)")
    }
}

@Test func duplicateNamedProvidersAndSelectorsAreDiagnosed() {
    for source in [
        """
        @ConstExpr public enum Root {}
        @ConstExprMembers(named: "Same") public extension Root {}
        @ConstExprMembers(named: "Same") public extension Root {}
        """,
        """
        @ConstExpr public func same() -> Int { 1 }
        @ConstExpr public func same() -> Int { 2 }
        """,
    ] {
        do {
            _ = try generatedRegistry(source)
            Issue.record("expected a duplicate-provider error")
        } catch { #expect(String(describing: error).contains("duplicate"), "\(error)") }
    }
}

@Test func invalidRegistryNamesAndDuplicateFilesCannotProduceOutput() {
    #expect(throws: RegistryGenerationError.self) {
        try RegistryGenerator.generate(module: "Model", registryName: "../Registry", sources: [])
    }
    #expect(throws: RegistryGenerationError.self) {
        try RegistryGenerator.generate(
            module: "Model", registryName: "Registry",
            sources: [.init(path: "Same.swift", text: ""), .init(path: "Same.swift", text: "")]
        )
    }
}
