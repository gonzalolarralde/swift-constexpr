import ConstExpr
import Foundation
import Testing

// Deliberately shadow the runtime's historical unqualified support names.
// Macro-generated peers must resolve through `_ConstExprRuntime` instead.
private struct ConstExprValue {}
private struct ConstExprRegistration {}
private struct ConstExprRegistry {}
private enum ConstExprValueError {}
private enum ConstExprStaticTypeDescriptor {}

private let arguments = 40

private protocol MacroExistentialFixture {}

private struct MacroExistentialValue: MacroExistentialFixture {}

private protocol MacroClassMarker: AnyObject {}

private final class MacroClassMarkerValue: MacroClassMarker {}

private protocol MacroValueMarker {}

private struct MacroValueMarkerValue: MacroValueMarker {}

private class MacroMarkerBase: MacroValueMarker {}

private final class MacroMarkerDerived: MacroMarkerBase {}

private final class MacroDescriptorInvocationCounter: @unchecked Sendable {
    var value = 0
}

private let macroDescriptorInvocationCounter = MacroDescriptorInvocationCounter()

@ConstExpr
private func existentialFixture(_ value: any MacroExistentialFixture) -> String {
    _ = value
    return "existential"
}

@ConstExpr
private func makeExistentialFixture() -> any MacroExistentialFixture {
    MacroExistentialValue()
}

@ConstExpr
private func makeClassMarkerFixture() -> any MacroClassMarker {
    MacroClassMarkerValue()
}

@ConstExpr
private func makeValueMarkerFixture() -> any MacroValueMarker {
    MacroValueMarkerValue()
}

@ConstExpr
private func makeOptionalClassMarkerFixture() -> (any MacroClassMarker)? {
    MacroClassMarkerValue()
}

@ConstExpr
private func makeOptionalValueMarkerFixture() -> (any MacroValueMarker)? {
    MacroValueMarkerValue()
}

@ConstExpr
private func makeClassMarkerArrayFixture() -> [any MacroClassMarker] {
    [MacroClassMarkerValue()]
}

@ConstExpr
private func makeValueMarkerArrayFixture() -> [any MacroValueMarker] {
    [MacroValueMarkerValue()]
}

@ConstExpr
private func makeBaseMarkerFixture() -> MacroMarkerBase {
    MacroMarkerDerived()
}

@ConstExpr
private func classifyOptionalMarkerFixture(_ value: AnyObject?) -> String {
    _ = value
    return "optionalAnyObject"
}

@ConstExpr
private func classifyOptionalMarkerFixture(_ value: Any?) -> String {
    _ = value
    return "optionalAny"
}

@ConstExpr
private func classifyMarkerArrayFixture(_ value: [AnyObject]) -> String {
    _ = value
    return "arrayAnyObject"
}

@ConstExpr
private func classifyMarkerArrayFixture(_ value: [Any]) -> String {
    _ = value
    return "arrayAny"
}

@ConstExpr
private func consumeValueMarkerFixture(_ value: any MacroValueMarker) -> String {
    _ = value
    return "protocol"
}

@ConstExpr
private func ambiguousMarkerFixture(_ value: any MacroValueMarker) -> String {
    _ = value
    macroDescriptorInvocationCounter.value += 1
    return "protocol"
}

@ConstExpr
private func ambiguousMarkerFixture(_ value: AnyObject) -> String {
    _ = value
    macroDescriptorInvocationCounter.value += 1
    return "anyObject"
}

@ConstExpr
private func recursiveDescriptorFixture(
    optional: Swift.Optional<any MacroValueMarker>,
    array: Swift.Array<any MacroValueMarker>,
    dictionary: Swift.Dictionary<String, any MacroValueMarker>,
    tuple: (any MacroValueMarker, [any MacroClassMarker])
) -> [String: (any MacroValueMarker)?] {
    _ = array
    _ = dictionary
    return ["value": optional ?? tuple.0]
}

@ConstExpr
private func classifyMarkerFixture(_ value: AnyObject) -> String {
    _ = value
    return "anyObject"
}

@ConstExpr
private func classifyMarkerFixture(_ value: Any) -> String {
    _ = value
    return "any"
}

@ConstExpr
private func makeAnyFixture() -> Any {
    7
}

@ConstExpr
private func makeOptionalAnyFixture() -> Any {
    Optional<Int>.none as Any
}

@ConstExpr
private func makeRenderableExistentialFixture() -> any CustomStringConvertible {
    8
}

@ConstExpr
private func makeOptionalRenderableExistentialFixture() -> (any CustomStringConvertible)? {
    9
}

@ConstExpr
private func makeRenderableExistentialArrayFixture() -> [any CustomStringConvertible] {
    [10, "eleven"]
}

@ConstExpr
private func macroHygieneFixture(_ value: Int = arguments) -> Int {
    value + 2
}

@ConstExpr
private struct MacroNominalFixture {
    enum Kind {
        case standard
        case alternate
    }

    private static let lexicalDefault = 41

    private(set) var value: Int
    let kind: Kind

    init(value: Int = lexicalDefault, kind: Kind = .standard) {
        self.value = value
        self.kind = kind
    }

    func replacing(with replacement: Self? = nil) -> Self {
        replacement ?? self
    }

    func routed(`repeat` amount: Int = 1) -> Int {
        value + amount
    }

    var copy: Self {
        self
    }
}

@ConstExpr
private struct `struct` {
    let value: Int

    init(_ value: Int = 5) {
        self.value = value
    }

    func `repeat`() -> Int {
        value
    }
}

@ConstExpr
private struct MacroArrayLiteralFixture: ExpressibleByArrayLiteral {
    let values: [Int]

    init(arrayLiteral elements: Int...) {
        values = elements
    }

    func sum() -> Int {
        values.reduce(0, +)
    }
}

@available(macOS 11, *)
@ConstExpr
private struct AvailableMacroFixture {
    init() {}

    func value() -> Int { 1 }
}

private let macroHardeningRegistry = #constExprRegistry(
    macroHygieneFixture(_:),
    existentialFixture(_:),
    makeExistentialFixture,
    makeClassMarkerFixture,
    makeValueMarkerFixture,
    makeOptionalClassMarkerFixture,
    makeOptionalValueMarkerFixture,
    makeClassMarkerArrayFixture,
    makeValueMarkerArrayFixture,
    makeBaseMarkerFixture,
    classifyMarkerFixture(_:) as (AnyObject) -> String,
    classifyMarkerFixture(_:) as (Any) -> String,
    classifyOptionalMarkerFixture(_:) as (AnyObject?) -> String,
    classifyOptionalMarkerFixture(_:) as (Any?) -> String,
    classifyMarkerArrayFixture(_:) as ([AnyObject]) -> String,
    classifyMarkerArrayFixture(_:) as ([Any]) -> String,
    consumeValueMarkerFixture(_:),
    ambiguousMarkerFixture(_:) as (any MacroValueMarker) -> String,
    ambiguousMarkerFixture(_:) as (AnyObject) -> String,
    recursiveDescriptorFixture(optional:array:dictionary:tuple:),
    makeAnyFixture,
    makeOptionalAnyFixture,
    makeRenderableExistentialFixture,
    makeOptionalRenderableExistentialFixture,
    makeRenderableExistentialArrayFixture,
    MacroNominalFixture.self,
    `struct`.self,
    MacroArrayLiteralFixture.self,
    AvailableMacroFixture.self
)

private enum MacroHardeningFixtureError: Error {
    case buildDirectoryNotFound(String)
    case swiftSyntaxCheckoutNotFound(String)
}

private final class MacroHardeningBundleToken: NSObject {}

private func activeSwiftPMBuildDirectory() throws -> URL {
    let bundle = Bundle(for: MacroHardeningBundleToken.self).bundleURL
        .resolvingSymlinksInPath()
    let directory = bundle.deletingLastPathComponent()
    guard FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("Modules").path
    ) else {
        throw MacroHardeningFixtureError.buildDirectoryNotFound(bundle.path)
    }
    return directory
}

private func swiftSyntaxShims(startingAt buildDirectory: URL) throws -> URL {
    var directory = buildDirectory
    while directory.path != "/" {
        let candidate = directory.appendingPathComponent(
            "checkouts/swift-syntax/Sources/_SwiftSyntaxCShims/include"
        )
        if FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        directory.deleteLastPathComponent()
    }
    throw MacroHardeningFixtureError.swiftSyntaxCheckoutNotFound(buildDirectory.path)
}

private func typecheckRewrittenFixture(_ source: String) throws -> (Int32, String) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ConstExprTypecheck-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: false
    )
    defer { try? FileManager.default.removeItem(at: directory) }

    let input = directory.appendingPathComponent("Rewritten.swift")
    try source.write(to: input, atomically: true, encoding: .utf8)

    let process = Process()
    let standardError = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = [
        "swiftc", "-typecheck", "-warnings-as-errors", input.path,
    ]
    process.standardOutput = Pipe()
    process.standardError = standardError
    try process.run()
    process.waitUntilExit()
    return (
        process.terminationStatus,
        String(
            decoding: standardError.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
    )
}

private func compileCustomGlobalActorFixture() throws -> (Int32, String) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ConstExprGlobalActor-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: false
    )
    defer { try? FileManager.default.removeItem(at: directory) }

    let input = directory.appendingPathComponent("Isolation.swift")
    try """
    import ConstExpr

    @globalActor actor Isolation {
        static let shared = Isolation()
    }

    @Isolation
    @ConstExpr
    func isolatedValue() -> Int { 1 }
    """.write(to: input, atomically: true, encoding: .utf8)

    let build = try activeSwiftPMBuildDirectory()
    let shims = try swiftSyntaxShims(startingAt: build)
    let process = Process()
    let standardError = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = [
        "swiftc", "-typecheck", "-warnings-as-errors",
        "-I", build.appendingPathComponent("Modules").path,
        "-Xcc", "-fmodule-map-file=\(shims.appendingPathComponent("module.modulemap").path)",
        "-Xcc", "-I", "-Xcc", shims.path,
        "-load-plugin-executable",
        "\(build.appendingPathComponent("ConstExprMacros-tool").path)#ConstExprMacros",
        input.path,
    ]
    process.standardOutput = Pipe()
    process.standardError = standardError
    try process.run()
    process.waitUntilExit()
    return (
        process.terminationStatus,
        String(
            decoding: standardError.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
    )
}

private func compileShadowedArrayLiteralProtocolFixture() throws -> (Int32, String) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ConstExprShadowedArrayLiteral-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: false
    )
    defer { try? FileManager.default.removeItem(at: directory) }

    let input = directory.appendingPathComponent("Shadowed.swift")
    try """
    import ConstExpr

    private protocol ExpressibleByArrayLiteral {}

    @ConstExpr
    private struct SyntacticLookalike: ExpressibleByArrayLiteral {
        init(arrayLiteral elements: Int...) {}
    }

    private let registry = #constExprRegistry(SyntacticLookalike.self)
    """.write(to: input, atomically: true, encoding: .utf8)

    let build = try activeSwiftPMBuildDirectory()
    let shims = try swiftSyntaxShims(startingAt: build)
    let process = Process()
    let standardError = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = [
        "swiftc", "-typecheck", "-warnings-as-errors",
        "-I", build.appendingPathComponent("Modules").path,
        "-Xcc", "-fmodule-map-file=\(shims.appendingPathComponent("module.modulemap").path)",
        "-Xcc", "-I", "-Xcc", shims.path,
        "-load-plugin-executable",
        "\(build.appendingPathComponent("ConstExprMacros-tool").path)#ConstExprMacros",
        input.path,
    ]
    process.standardOutput = Pipe()
    process.standardError = standardError
    try process.run()
    process.waitUntilExit()
    return (
        process.terminationStatus,
        String(
            decoding: standardError.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
    )
}

@Test func hardenedMacroPeersCompileAndRegisterAllSupportedShapes() {
    #expect(macroHardeningRegistry.registrations.contains { registration in
        registration.name == "macroHygieneFixture"
    })
    #expect(macroHardeningRegistry.registrations.contains { registration in
        registration.name == "existentialFixture"
            && registration.parameterTypes.first == (any MacroExistentialFixture).self
    })
    #expect(macroHardeningRegistry.registrations.contains { registration in
        registration.name == "replacing"
            && registration.resultType == MacroNominalFixture.self
    })
    #expect(macroHardeningRegistry.registrations.contains { registration in
        registration.name == "makeOptionalRenderableExistentialFixture"
            && registration.resultType == ((any CustomStringConvertible)?).self
    })
    #expect(macroHardeningRegistry.registrations.contains { registration in
        registration.name == "makeRenderableExistentialArrayFixture"
            && registration.resultType == ([any CustomStringConvertible]).self
    })
    #expect(macroHardeningRegistry.registrations.contains { registration in
        registration.name == "routed" && registration.parameterLabels == ["repeat"]
    })
    #expect(macroHardeningRegistry.registrations.contains { registration in
        registration.name == "repeat"
            && registration.ownerType == `struct`.self
    })
    let arrayLiteralRegistration = macroHardeningRegistry.registrations.first { registration in
        registration.kind == .arrayLiteral
            && registration.resultType == MacroArrayLiteralFixture.self
    }
    #expect(arrayLiteralRegistration?.arrayLiteralElementType == Int.self)
    #expect(arrayLiteralRegistration?.maximumArrayLiteralElementCount == 32)
    #expect(macroHardeningRegistry.registrations.contains { registration in
        registration.ownerType == AvailableMacroFixture.self
    })
}

@Test func generatedArrayLiteralRegistrationCompilesAndEvaluatesNestedMembers() {
    let result = ConstExprRunner(registry: macroHardeningRegistry).rewrite(
        source: "let total: Int = ([1, 2, 3] as MacroArrayLiteralFixture).sum()"
    )

    #expect(result.source == "let total: Int = 6")
    #expect(result.diagnostics.isEmpty)
}

@Test func customGlobalActorAttributesAreRejectedBeforePeerEmission() throws {
    let compilation = try compileCustomGlobalActorFixture()

    #expect(compilation.0 != 0)
    #expect(
        compilation.1.contains(
            "declaration attribute @Isolation may impose isolation or semantic transforms that @ConstExpr cannot prove safe; use manual registration"
        )
    )
    #expect(!compilation.1.contains("call to global actor-isolated"))
}

@Test func shadowedArrayLiteralProtocolUsesNonconformingProbeOverload() throws {
    let compilation = try compileShadowedArrayLiteralProtocolFixture()

    #expect(compilation.0 == 0)
    #expect(compilation.1.isEmpty)
}


@Test func generatedExistentialResultsFlowIntoExistentialParameters() {
    let result = ConstExprRunner(registry: macroHardeningRegistry).rewrite(
        source: "let value = existentialFixture(makeExistentialFixture())"
    )

    #expect(result.source == "let value = \"existential\"")
    #expect(result.diagnostics.isEmpty)
}

@Test func generatedClassBoundExistentialResultsSelectAnyObjectOnlyWhenValid() throws {
    let classFactory = try #require(
        macroHardeningRegistry.registrations.first {
            $0.name == "makeClassMarkerFixture"
        }
    )
    let valueFactory = try #require(
        macroHardeningRegistry.registrations.first {
            $0.name == "makeValueMarkerFixture"
        }
    )
    #expect(try classFactory.invoke().isStaticallyAnyObject)
    #expect(try !valueFactory.invoke().isStaticallyAnyObject)

    let result = ConstExprRunner(registry: macroHardeningRegistry).rewrite(
        source: """
            let classBound = classifyMarkerFixture(makeClassMarkerFixture())
            let unconstrained = classifyMarkerFixture(makeValueMarkerFixture())
            """
    )

    #expect(result.source == """
        let classBound = "anyObject"
        let unconstrained = "any"
        """)
    #expect(result.diagnostics.isEmpty)
}

@Test func generatedRecursiveExistentialDescriptorsPreserveStaticConversions() {
    let result = ConstExprRunner(registry: macroHardeningRegistry).rewrite(
        source: """
            let classOptional = classifyOptionalMarkerFixture(makeOptionalClassMarkerFixture())
            let valueOptional = classifyOptionalMarkerFixture(makeOptionalValueMarkerFixture())
            let classArray = classifyMarkerArrayFixture(makeClassMarkerArrayFixture())
            let valueArray = classifyMarkerArrayFixture(makeValueMarkerArrayFixture())
            let protocolBase = consumeValueMarkerFixture(makeBaseMarkerFixture())
            """
    )

    #expect(result.source == """
        let classOptional = "optionalAnyObject"
        let valueOptional = "optionalAny"
        let classArray = "arrayAnyObject"
        let valueArray = "arrayAny"
        let protocolBase = "protocol"
        """)
    #expect(result.diagnostics.isEmpty)
}

@Test func generatedNonclassProtocolAndAnyObjectAmbiguityNeverExecutes() {
    let result = ConstExprRunner(registry: macroHardeningRegistry).rewrite(
        source: "let value = ambiguousMarkerFixture(makeBaseMarkerFixture())"
    )

    #expect(result.source == "let value = ambiguousMarkerFixture(makeBaseMarkerFixture())")
    #expect(result.diagnostics.map(\.code) == ["ambiguous-overload"])
    #expect(macroDescriptorInvocationCounter.value == 0)
}

@Test func generatedDescriptorsRecurseThroughGenericAndSugarContainers() throws {
    let registration = try #require(
        macroHardeningRegistry.registrations.first {
            $0.name == "recursiveDescriptorFixture"
        }
    )

    func shape(_ descriptor: _ConstExprRuntime.StaticTypeDescriptor) -> String {
        switch descriptor {
        case .leaf(_, let sourceName, let existential, let classBound, let accepts):
            return "leaf(\(sourceName ?? "nil"),\(existential),\(classBound),\(accepts != nil))"
        case .optional(let wrapped):
            return "optional(\(shape(wrapped)))"
        case .array(let element):
            return "array(\(shape(element)))"
        case .dictionary(let key, let value):
            return "dictionary(\(shape(key)),\(shape(value)))"
        case .tuple(let elements):
            return "tuple(\(elements.map(shape).joined(separator: ",")))"
        }
    }

    #expect(registration.parameterTypeDescriptors.map(shape) == [
        "optional(leaf(any MacroValueMarker,true,false,true))",
        "array(leaf(any MacroValueMarker,true,false,true))",
        "dictionary(leaf(String,false,false,false),leaf(any MacroValueMarker,true,false,true))",
        "tuple(leaf(any MacroValueMarker,true,false,true),array(leaf(any MacroClassMarker,true,true,true)))",
    ])
    #expect(
        shape(registration.resultTypeDescriptor)
            == "dictionary(leaf(String,false,false,false),optional(leaf(any MacroValueMarker,true,false,true)))"
    )
}

@Test func generatedErasedResultsMaterializeWithoutChangingTheirStaticTypes() throws {
    let result = ConstExprRunner(registry: macroHardeningRegistry).rewrite(
        source: """
            let anyValue = makeAnyFixture()
            let optionalAny = makeOptionalAnyFixture()
            let existential = makeRenderableExistentialFixture()
            let optionalExistential = makeOptionalRenderableExistentialFixture()
            let existentialArray = makeRenderableExistentialArrayFixture()
            """
    )

    #expect(result.source == """
        let anyValue = ((7) as Any)
        let optionalAny = ((nil as Swift.Optional<Swift.Int>) as Any)
        let existential = ((8) as any CustomStringConvertible)
        let optionalExistential = (9) as (any CustomStringConvertible)?
        let existentialArray = ([10, "eleven"]) as [any CustomStringConvertible]
        """)
    #expect(result.diagnostics.isEmpty)

    let typecheck = try typecheckRewrittenFixture(result.source + """

        func classifyAny(_ value: Int) -> Int { value }
        func classifyAny(_ value: Any) -> String { "any" }
        func classifyExistential(_ value: Int) -> Int { value }
        func classifyExistential(_ value: any CustomStringConvertible) -> String { "existential" }
        func classifyOptionalExistential(_ value: Int?) -> Int { value ?? 0 }
        func classifyOptionalExistential(_ value: (any CustomStringConvertible)?) -> String { "optional existential" }
        func classifyExistentialArray(_ value: [Int]) -> Int { value.count }
        func classifyExistentialArray(_ value: [any CustomStringConvertible]) -> String { "existential array" }
        let anyProof: String = classifyAny(anyValue)
        let optionalAnyProof: String = classifyAny(optionalAny)
        let existentialProof: String = classifyExistential(existential)
        let optionalExistentialProof: String = classifyOptionalExistential(optionalExistential)
        let existentialArrayProof: String = classifyExistentialArray(existentialArray)
        """)
    #expect(typecheck.0 == 0)
    #expect(typecheck.1.isEmpty)
}
