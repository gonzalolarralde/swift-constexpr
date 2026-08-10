import Testing
@testable import ConstExpr

@Test func labelKeyedInvocationHandlesManySameTypedDefaultsByName() throws {
    let registration = ConstExprRegistration.labelKeyed(
        name: "describe",
        kind: .function,
        parameterLabels: ["name", "products", "targets", "enabled"],
        parameterTypes: [String.self, [String].self, [String].self, Bool.self],
        defaultedParameters: [1, 2, 3],
        resultType: String.self
    ) { _, arguments in
        let name = try arguments.require("name", as: String.self)
        let products = try arguments.optional("products", as: [String].self) ?? []
        let targets = try arguments.optional("targets", as: [String].self) ?? []
        let enabled = try arguments.optional("enabled", as: Bool.self) ?? true
        return ConstExprValue(
            "\(name)|\(products.joined(separator: ","))|\(targets.joined(separator: ","))|\(enabled)"
        )
    }
    let runner = ConstExprRunner(registry: ConstExprRegistry(registrations: [registration]))

    let result = runner.rewrite(source: """
        let first = describe(name: "Library", targets: ["Core"], enabled: false)
        let second = describe(name: "Library")
        """)

    #expect(result.source == """
        let first = "Library||Core|false"
        let second = "Library|||true"
        """)
    #expect(result.diagnostics.isEmpty)
    #expect(registration.defaultArgumentCount == 3)
    #expect(registration.minimumArgumentCount == 1)
    #expect(registration.maximumArgumentCount == 4)
}

@Test func labelKeyedArgumentsRejectUnknownDuplicateAndOmittedLabels() throws {
    let arguments = try ConstExprInvocationArguments(
        parameterLabels: ["required", "defaulted"],
        values: [ConstExprValue(1), nil]
    )
    #expect(try arguments.wasProvided("required"))
    #expect(try !arguments.wasProvided("defaulted"))
    #expect(throws: ConstExprInvocationArgumentsError.omittedValue("defaulted")) {
        try arguments.require("defaulted", as: Int.self)
    }
    #expect(throws: ConstExprInvocationArgumentsError.unknownLabel("missing")) {
        try arguments.wasProvided("missing")
    }
    #expect(throws: ConstExprInvocationArgumentsError.duplicateLabel("value")) {
        try ConstExprInvocationArguments(
            parameterLabels: ["value", "value"],
            values: [ConstExprValue(1), ConstExprValue(2)]
        )
    }
}
