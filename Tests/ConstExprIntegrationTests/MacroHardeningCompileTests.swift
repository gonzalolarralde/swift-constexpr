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

let arguments = 40

protocol MacroExistentialFixture {}

struct MacroExistentialValue: MacroExistentialFixture {}

protocol MacroClassMarker: AnyObject {}

final class MacroClassMarkerValue: MacroClassMarker {}

protocol MacroValueMarker {}

struct MacroValueMarkerValue: MacroValueMarker {}

class MacroMarkerBase: MacroValueMarker {}

final class MacroMarkerDerived: MacroMarkerBase {}

final class MacroDescriptorInvocationCounter: @unchecked Sendable {
    var value = 0
}
let macroDescriptorInvocationCounter = MacroDescriptorInvocationCounter()

@ConstExpr
func existentialFixture(_ value: any MacroExistentialFixture) -> String {
    _ = value
    return "existential"
}

@ConstExpr
func makeExistentialFixture() -> any MacroExistentialFixture {
    MacroExistentialValue()
}

@ConstExpr
func makeClassMarkerFixture() -> any MacroClassMarker {
    MacroClassMarkerValue()
}

@ConstExpr
func makeValueMarkerFixture() -> any MacroValueMarker {
    MacroValueMarkerValue()
}

@ConstExpr
func makeOptionalClassMarkerFixture() -> (any MacroClassMarker)? {
    MacroClassMarkerValue()
}

@ConstExpr
func makeOptionalValueMarkerFixture() -> (any MacroValueMarker)? {
    MacroValueMarkerValue()
}

@ConstExpr
func makeClassMarkerArrayFixture() -> [any MacroClassMarker] {
    [MacroClassMarkerValue()]
}

@ConstExpr
func makeValueMarkerArrayFixture() -> [any MacroValueMarker] {
    [MacroValueMarkerValue()]
}

@ConstExpr
func makeBaseMarkerFixture() -> MacroMarkerBase {
    MacroMarkerDerived()
}

@ConstExpr
func classifyOptionalMarkerFixture(_ value: AnyObject?) -> String {
    _ = value
    return "optionalAnyObject"
}

@ConstExpr
func classifyOptionalMarkerFixture(_ value: Any?) -> String {
    _ = value
    return "optionalAny"
}

@ConstExpr
func classifyMarkerArrayFixture(_ value: [AnyObject]) -> String {
    _ = value
    return "arrayAnyObject"
}

@ConstExpr
func classifyMarkerArrayFixture(_ value: [Any]) -> String {
    _ = value
    return "arrayAny"
}

@ConstExpr
func consumeValueMarkerFixture(_ value: any MacroValueMarker) -> String {
    _ = value
    return "protocol"
}

@ConstExpr
func ambiguousMarkerFixture(_ value: any MacroValueMarker) -> String {
    _ = value
    macroDescriptorInvocationCounter.value += 1
    return "protocol"
}

@ConstExpr
func ambiguousMarkerFixture(_ value: AnyObject) -> String {
    _ = value
    macroDescriptorInvocationCounter.value += 1
    return "anyObject"
}

@ConstExpr
func recursiveDescriptorFixture(
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
func classifyMarkerFixture(_ value: AnyObject) -> String {
    _ = value
    return "anyObject"
}

@ConstExpr
func classifyMarkerFixture(_ value: Any) -> String {
    _ = value
    return "any"
}

@ConstExpr
func makeAnyFixture() -> Any {
    7
}

@ConstExpr
func makeOptionalAnyFixture() -> Any {
    Optional<Int>.none as Any
}

@ConstExpr
func makeRenderableExistentialFixture() -> any CustomStringConvertible {
    8
}

@ConstExpr
func makeOptionalRenderableExistentialFixture() -> (any CustomStringConvertible)? {
    9
}

@ConstExpr
func makeRenderableExistentialArrayFixture() -> [any CustomStringConvertible] {
    [10, "eleven"]
}

@ConstExpr
func macroHygieneFixture(_ value: Int = arguments) -> Int {
    value + 2
}

@ConstExpr
struct MacroNominalFixture {
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
struct `struct` {
    let value: Int

    init(_ value: Int = 5) {
        self.value = value
    }

    func `repeat`() -> Int {
        value
    }
}

@ConstExpr
struct MacroArrayLiteralFixture: ExpressibleByArrayLiteral {
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
struct AvailableMacroFixture {
    init() {}

    func value() -> Int { 1 }
}

let macroHardeningRegistry = #constExprRegistry(
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

enum MacroHardeningFixtureError: Error {
    case buildDirectoryNotFound(String)
    case swiftSyntaxCheckoutNotFound(String)
}

final class MacroHardeningBundleToken: NSObject {}

func activeSwiftPMBuildDirectory() throws -> URL {
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

func swiftSyntaxShims(startingAt buildDirectory: URL) throws -> URL {
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

func typecheckRewrittenFixture(_ source: String) throws -> (Int32, String) {
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

func compileCustomGlobalActorFixture() throws -> (Int32, String) {
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

func compileShadowedArrayLiteralProtocolFixture() throws -> (Int32, String) {
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
