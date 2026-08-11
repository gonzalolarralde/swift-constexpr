import ConstExprPackageInterfaceConsumerFixture
import Foundation
import Testing

private enum PackageInterfaceTestError: Error {
    case buildDirectoryNotFound(String)
    case swiftSyntaxCheckoutNotFound(String)
    case interfaceNotCreated(String)
}

private final class PackageInterfaceBundleToken: NSObject {}

private func packageInterfaceBuildDirectory() throws -> URL {
    let bundle = Bundle(for: PackageInterfaceBundleToken.self).bundleURL
        .resolvingSymlinksInPath()
    let directory = bundle.deletingLastPathComponent()
    guard FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("Modules").path
    ) else {
        throw PackageInterfaceTestError.buildDirectoryNotFound(bundle.path)
    }
    return directory
}

private func packageInterfaceSwiftSyntaxShims(
    startingAt buildDirectory: URL
) throws -> URL {
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
    throw PackageInterfaceTestError.swiftSyntaxCheckoutNotFound(
        buildDirectory.path
    )
}

private func emitPackageAccessInterface() throws -> (Int32, String, String) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ConstExprPackageInterface-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: false
    )
    defer { try? FileManager.default.removeItem(at: directory) }

    let input = directory.appendingPathComponent("Fixture.swift")
    let interface = directory.appendingPathComponent("Fixture.swiftinterface")
    let module = directory.appendingPathComponent("Fixture.swiftmodule")
    try """
    internal import ConstExpr

    public struct CleanPublicAPI {
        public let value: Int

        @ConstExpr(registrationAccess: .package)
        public init(value: Int = 1) {
            self.value = value
        }
    }

    public enum CleanNamespace {}

    @ConstExpr(registrationAccess: .package)
    public struct CleanExtensionAPI {}

    @ConstExprMembers(named: "Factories", registrationAccess: .package)
    public extension CleanExtensionAPI {
        static func make(_ value: Int) -> Self { Self() }

        @ConstExprIgnored
        static func processDependentValue() -> Int {
            fatalError("must remain compiler work")
        }

        static func genericIdentity<T>(_ value: T) -> T { value }
    }

    extension CleanNamespace {
        @ConstExpr(registrationAccess: .package)
        public struct NestedVersion {
            public let value: Int

            public init(_ value: Int) {
                self.value = value
            }

            public func adding(_ amount: Int) -> Int {
                value + amount
            }

            @available(macOS 11, *)
            public static var introduced: Self { Self(10) }

            @available(macOS, introduced: 11, deprecated: 99)
            public static var legacy: Self { Self(20) }

            @available(*, unavailable, renamed: "introduced")
            public static var unavailableAlias: Self { Self(0) }
        }
    }
    """.write(to: input, atomically: true, encoding: .utf8)

    let build = try packageInterfaceBuildDirectory()
    let shims = try packageInterfaceSwiftSyntaxShims(startingAt: build)
    let process = Process()
    let standardError = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = [
        "swiftc", "-emit-module", "-enable-library-evolution",
        "-warnings-as-errors", "-swift-version", "6",
        "-module-name", "CleanPublicAPIModule",
        "-package-name", "ConstExprInterfaceFixture",
        "-emit-module-path", module.path,
        "-emit-module-interface-path", interface.path,
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
    let errors = String(
        decoding: standardError.fileHandleForReading.readDataToEndOfFile(),
        as: UTF8.self
    )
    guard FileManager.default.fileExists(atPath: interface.path) else {
        if process.terminationStatus == 0 {
            throw PackageInterfaceTestError.interfaceNotCreated(interface.path)
        }
        return (process.terminationStatus, errors, "")
    }
    return (
        process.terminationStatus,
        errors,
        try String(contentsOf: interface, encoding: .utf8)
    )
}

private func typecheckMissingNamedExtensionRoot() throws -> (Int32, String) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ConstExprMissingRoot-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: false
    )
    defer { try? FileManager.default.removeItem(at: directory) }

    let input = directory.appendingPathComponent("Fixture.swift")
    try """
    import ConstExpr

    struct MissingRoot {}

    @ConstExprMembers(named: "Factories")
    extension MissingRoot {
        static func make() -> Self { Self() }
    }
    """.write(to: input, atomically: true, encoding: .utf8)

    let build = try packageInterfaceBuildDirectory()
    let shims = try packageInterfaceSwiftSyntaxShims(startingAt: build)
    let process = Process()
    let standardError = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = [
        "swiftc", "-typecheck", "-warnings-as-errors", "-swift-version", "6",
        "-module-name", "MissingRootFixture",
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

@Test func packagePeerIsCallableFromSiblingTarget() {
    #expect(packageInterfaceRegistrationCount() == 7)
    #expect(packageInterfaceNamedExtensionRewrite() == """
        let initialized = PackageInterfaceFixture(value: 2)
        let doubled = 12
        """)
    #expect(packageInterfaceNestedNominalRewrite() == """
        let initialized = 6
        let introduced = 11
        let legacy = PackageInterfaceNamespace.NestedVersion.legacy.adding(2)
        """)
    #expect(packageInterfaceNestedAvailabilityPolicyIsApplied())
}

@Test func packageAccessPeerDoesNotLeakIntoPublicInterface() throws {
    let result = try emitPackageAccessInterface()
    #expect(result.0 == 0, Comment(rawValue: result.1))
    #expect(!result.2.contains("import ConstExpr"))
    #expect(!result.2.contains("__constExpr"))
    #expect(result.2.contains("public struct CleanPublicAPI"))
    #expect(result.2.contains("public init(value: Swift.Int = 1)"))
    #expect(result.2.contains("public struct CleanExtensionAPI"))
    #expect(result.2.contains("public static func make(_ value: Swift.Int)"))
    #expect(result.2.contains("public struct NestedVersion"))
}

@Test func namedExtensionRequiresPrimaryNominalProvider() throws {
    let result = try typecheckMissingNamedExtensionRoot()
    #expect(result.0 != 0)
    #expect(result.1.contains("MissingRoot__constExpr"))
    #expect(result.1.contains("cannot find type"))
}
