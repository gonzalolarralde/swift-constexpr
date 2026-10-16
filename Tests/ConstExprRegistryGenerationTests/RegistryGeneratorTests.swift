import ConstExprRegistryGeneration
import Testing

@Test func generatesSimpleNominalRegistry() throws {
    let output = try RegistryGenerator.generate(
        module: "Model", registryName: "ModelRegistry",
        sources: [.init(path: "Model.swift", text: """
        import ConstExpr
        @ConstExpr(registrationAccess: .package)
        public enum Encoder {
            public static func byte(_ value: UInt8) -> [UInt8] { [value] }
        }
        """)]
    )
    #expect(output.contains("Model.Encoder.self"))
    #expect(output.contains("enum ModelRegistry"))
}

func generatedRegistry(_ text: String, sameModule: Bool = false) throws -> String {
    try RegistryGenerator.generate(
        module: "Model", registryName: "ModelRegistry", sameModule: sameModule,
        sources: [.init(path: "Model.swift", text: text)]
    )
}

@Test func discoversNestedTypesFreeFunctionsOverloadsAndConstants() throws {
    let output = try generatedRegistry("""
    import ConstExpr
    @ConstExpr(registrationAccess: .package)
    public enum Container {
        @ConstExpr(registrationAccess: .package)
        public enum Kind { case first, second }
    }
    @ConstExpr(registrationAccess: .package)
    public func transform(_ value: Int) -> String { String(value) }
    @ConstExpr(registrationAccess: .package)
    public func transform(_ value: String) -> String { value }
    @ConstExpr(registrationAccess: .package)
    public let version = 7
    """)
    #expect(output.contains("Model.Container.self"))
    #expect(output.contains("Model.Container.Kind.self"))
    #expect(output.contains("Model.transform(_:) as (Int) -> String"))
    #expect(output.contains("Model.transform(_:) as (String) -> String"))
    #expect(output.contains("Model.version"))
}

@Test func extensionDiscoveryUsesTheActualMemberMacrosFiltering() throws {
    let output = try generatedRegistry("""
    import ConstExpr
    public struct Builder {}
    @ConstExprMembers(registrationAccess: .package)
    public extension Builder {
        static func buildExpression(_ value: Int) -> String { String(value) }
        static func buildBlock() -> String { "empty" }
        @ConstExprIgnored static func ignored() -> Int { fatalError() }
        static func unsupported<T>(_ value: T) -> T { value }
        mutating func mutate() -> Int { 1 }
        @ConstExpr(registrationAccess: .package)
        public static func explicit(_ value: UInt8) -> UInt8 { value }
        public enum Nested { case value }
    }
    """)
    #expect(output.contains("Model.Builder.buildExpression(_:) as (Int) -> String"))
    #expect(output.contains("Model.Builder.buildBlock as () -> String"))
    #expect(output.contains("Model.Builder.Nested.self"))
    #expect(output.components(separatedBy: "Model.Builder.explicit").count == 2)
    #expect(!output.contains("ignored"))
    #expect(!output.contains("unsupported"))
    #expect(!output.contains("mutate"))
}

@Test func combinesNamedExtensionsWithoutDuplicatingTheirRoot() throws {
    let output = try generatedRegistry("""
    import ConstExpr
    @ConstExpr(registrationAccess: .package)
    public struct Label { public let value: String }
    @ConstExprMembers(named: "Formatting", registrationAccess: .package)
    public extension Label {
        static func format(_ value: String) -> String { value }
        @ConstExpr(registrationAccess: .package)
        public static func direct() -> Int { 7 }
    }
    """)
    #expect(output.contains("#constExprRegistry(for: Model.Label.self, extensions: [\"Formatting\"])"))
    #expect(output.components(separatedBy: "Model.Label.self").count == 2)
    #expect(output.contains("Model.Label.direct as () -> Int"))
    #expect(!output.contains("Model.Label.format"))
}

@Test func directlyAnnotatedNominalMembersAreNotRegisteredTwice() throws {
    let output = try generatedRegistry("""
    import ConstExpr
    @ConstExpr(registrationAccess: .package)
    public struct Owner {
        public struct Value {}
        @ConstExpr(registrationAccess: .package)
        public static func value(_ item: Value) -> Value { item }
        @ConstExpr(registrationAccess: .package)
        public init() {}
        @ConstExpr(registrationAccess: .package)
        public var count: Int { 7 }
    }
    """)
    #expect(output.contains("Model.Owner.self"))
    #expect(!output.contains("Model.Owner.value"))
    #expect(!output.contains("Model.Owner.init"))
    #expect(!output.contains("\\Model.Owner.count"))
}

@Test func directPropertiesInitializersAndSubscriptsHaveSelectableReferences() throws {
    let output = try generatedRegistry("""
    import ConstExpr
    public struct Owner {
        @ConstExpr(registrationAccess: .package)
        public init(value: Int) {}
        @ConstExpr(registrationAccess: .package)
        public var value: Int { 7 }
        @ConstExpr(registrationAccess: .package)
        public static var shared: Int { 8 }
        @ConstExpr(registrationAccess: .package)
        public subscript(index: Int) -> Int { index }
        @ConstExpr(registrationAccess: .package)
        public func method(_ value: Int) -> Int { value }
    }
    """)
    #expect(output.contains("Model.Owner.init(value:) as (Int) -> Model.Owner"))
    #expect(output.contains("\\Model.Owner.value"))
    #expect(output.contains("Model.Owner.shared"))
    #expect(output.contains("Model.Owner.subscript__constExpr("))
    #expect(output.contains("Model.Owner.method(_:) as (Model.Owner) -> (Int) -> Int"))
}

@Test func generationIsDeterministicAcrossSourceEnumerationOrder() throws {
    let sources: [RegistryGenerator.Source] = [
        .init(path: "Z.swift", text: "@ConstExpr public enum Z {}"),
        .init(path: "A.swift", text: "@ConstExpr public enum A {}"),
    ]
    let first = try RegistryGenerator.generate(module: "Model", registryName: "Registry", sources: sources)
    let second = try RegistryGenerator.generate(module: "Model", registryName: "Registry", sources: sources.reversed())
    #expect(first == second)
}

@Test func ordinaryFunctionBodiesAreNotEvaluatedOrConfusedWithConditionalProviders() throws {
    let output = try generatedRegistry("""
    @ConstExpr public func neverExecute() -> Int {
        #if os(macOS)
        fatalError("generation must not execute this")
        #else
        fatalError("neither branch may execute")
        #endif
    }
    """)
    #expect(output.contains("Model.neverExecute as () -> Int"))
    #expect(!output.contains("fatalError"))
}

@Test func internalProvidersCanBeGeneratedInsideTheirOwnModule() throws {
    let output = try generatedRegistry("@ConstExpr enum InternalType {}", sameModule: true)
    #expect(!output.contains("import Model"))
    #expect(output.contains("Model.InternalType.self"))
}
