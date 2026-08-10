@testable import ConstExprMacros
import SwiftParser
import SwiftSyntax
import XCTest

final class ConstExprAvailabilitySyntaxTests: XCTestCase {
    func testPackageDescriptionAvailabilityAndDisfavoredMetadata() throws {
        let file = Parser.parse(source: """
        @available(_PackageDescription, introduced: 5.9, obsoleted: 6.2)
        @_disfavoredOverload
        func value() -> Int { 1 }
        """)
        let function = try XCTUnwrap(
            file.statements.first?.item.as(DeclSyntax.self)?
                .as(FunctionDeclSyntax.self)
        )

        let metadata = ConstExprRegistrationMetadataSource(
            attributes: function.attributes
        )
        XCTAssertTrue(metadata.isDisfavoredOverload)
        XCTAssertTrue(
            metadata.arguments.contains("domain: \"_PackageDescription\""),
            metadata.arguments
        )
        XCTAssertTrue(
            metadata.arguments.contains("major: 5, minor: 9, patch: 0"),
            metadata.arguments
        )
        XCTAssertTrue(
            metadata.arguments.contains("major: 6, minor: 2, patch: 0"),
            metadata.arguments
        )
        XCTAssertTrue(metadata.arguments.contains("isDisfavoredOverload: true"))
        XCTAssertTrue(metadata.hasObsoletedAvailability)
    }

    func testUnavailableWildcardIsRecorded() throws {
        let file = Parser.parse(source: """
        @available(*, unavailable)
        func value() -> Int { 1 }
        """)
        let function = try XCTUnwrap(
            file.statements.first?.item.as(DeclSyntax.self)?
                .as(FunctionDeclSyntax.self)
        )
        let metadata = ConstExprRegistrationMetadataSource(
            attributes: function.attributes
        )
        XCTAssertTrue(
            metadata.arguments.contains("domain: \"*\", isUnavailable: true")
        )
        XCTAssertTrue(metadata.isUnconditionallyUnavailable)
    }

    func testDeprecatedAvailabilityIsRecordedAsACompilerDiagnosticBoundary() throws {
        let file = Parser.parse(source: """
        @available(_PackageDescription, introduced: 5.0, deprecated: 6.1)
        func versioned() -> Int { 1 }

        @available(*, deprecated, message: "use another declaration")
        func always() -> Int { 2 }
        """)
        let functions = file.statements.compactMap {
            $0.item.as(DeclSyntax.self)?.as(FunctionDeclSyntax.self)
        }
        XCTAssertEqual(functions.count, 2)

        let versionedMetadata = ConstExprRegistrationMetadataSource(
            attributes: functions[0].attributes
        )
        let versioned = versionedMetadata.arguments
        XCTAssertTrue(versioned.contains("deprecated:"), versioned)
        XCTAssertTrue(versioned.contains("major: 6, minor: 1, patch: 0"), versioned)

        let alwaysMetadata = ConstExprRegistrationMetadataSource(
            attributes: functions[1].attributes
        )
        let always = alwaysMetadata.arguments
        XCTAssertTrue(always.contains("domain: \"*\", isDeprecated: true"), always)
        XCTAssertTrue(versionedMetadata.hasDeprecatedAvailability)
        XCTAssertTrue(alwaysMetadata.hasDeprecatedAvailability)
    }
}
