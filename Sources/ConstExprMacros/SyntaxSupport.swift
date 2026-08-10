import Foundation
import SwiftSyntax
import SwiftSyntaxMacros

extension SyntaxProtocol {
    var constExprSource: String {
        trimmed.description
    }
}

extension TokenSyntax {
    /// The semantic spelling of an identifier, without raw-identifier quotes.
    var constExprIdentifier: String {
        let source = trimmed.description
        guard source.count >= 2, source.first == "`", source.last == "`" else {
            return source
        }
        return String(source.dropFirst().dropLast())
    }

    /// A source-valid reference to this identifier, retaining raw-identifier
    /// quotes when the declaration used them.
    var constExprIdentifierReference: String {
        trimmed.description
    }

    /// `MacroExpansionContext.makeUniqueName` intentionally returns a token
    /// in the compiler's `$s…` namespace. That token is valid when retained as
    /// syntax, but becomes a property-wrapper projection if interpolated into
    /// source text. Encode it into an ordinary Swift identifier before using
    /// it in string-built peers.
    var constExprSourceSafeGeneratedIdentifier: String {
        // Keep generated peers readable while retaining the uniqueness of the
        // complete compiler spelling. Swift's `Hasher` is process-randomized,
        // so use a deterministic FNV-1a digest for stable macro expansions.
        var digest: UInt64 = 14_695_981_039_346_656_037
        for byte in text.utf8 {
            digest ^= UInt64(byte)
            digest &*= 1_099_511_628_211
        }
        return "__constExprMacro_\(String(digest, radix: 36))"
    }
}

enum ConstExprAccessLevel: Int, Comparable {
    case `private` = 0
    case `fileprivate` = 1
    case `internal` = 2
    case package = 3
    case `public` = 4

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

extension DeclModifierListSyntax {
    func constExprContains(_ keyword: Keyword) -> Bool {
        contains { $0.name.tokenKind == .keyword(keyword) }
    }

    /// Access modifiers with details such as `private(set)` constrain the
    /// setter, not the getter that an adapter reads.
    var constExprAccessLevel: ConstExprAccessLevel {
        for modifier in self where modifier.detail == nil {
            switch modifier.name.tokenKind {
            case .keyword(.open), .keyword(.public): return .public
            case .keyword(.package): return .package
            case .keyword(.fileprivate): return .fileprivate
            case .keyword(.private): return .private
            default: continue
            }
        }
        return .internal
    }

    var constExprAccessPrefix: String {
        switch constExprAccessLevel {
        case .public: return "public "
        case .package: return "package "
        case .fileprivate: return "fileprivate "
        case .private: return "private "
        case .internal: return ""
        }
    }
}

extension AttributeListSyntax {
    var constExprPreservedPeerAttributes: String {
        compactMap { element -> String? in
            guard let attribute = element.as(AttributeSyntax.self) else { return nil }
            let name = attribute.attributeName.constExprSource
            guard name == "available" || name == "_spi" else { return nil }
            return attribute.constExprSource
        }.joined(separator: "\n")
    }

    var constExprHasAvailabilityConstraint: Bool {
        contains { element in
            guard let attribute = element.as(AttributeSyntax.self) else { return false }
            return attribute.attributeName.constExprSource == "available"
        }
    }

    var constExprHasSPIConstraint: Bool {
        contains { element in
            guard let attribute = element.as(AttributeSyntax.self) else { return false }
            return attribute.attributeName.constExprSource == "_spi"
        }
    }

    var constExprGlobalActorName: String? {
        for element in self {
            guard let attribute = element.as(AttributeSyntax.self) else { continue }
            let name = attribute.attributeName.constExprSource.split(separator: ".").last.map(String.init) ?? ""
            if name == "MainActor" || name.hasSuffix("Actor") {
                return name
            }
        }
        return nil
    }

    /// Attributes are not semantically resolved by a syntax macro. Preserve a
    /// deliberately small set whose effects cannot change which declaration
    /// is called; every other attribute may be a custom global actor or an
    /// attached transform and must be rejected conservatively.
    var constExprUnsupportedSemanticAttributeName: String? {
        let safeNames: Set<String> = [
            "ConstExpr",
            "available",
            "_spi",
            "discardableResult",
            "inlinable",
            "_alwaysEmitIntoClient",
            "_transparent",
            "inline",
            "usableFromInline",
            "warn_unqualified_access",
            "_documentation",
            "backDeployed",
        ]
        for element in self {
            guard let attribute = element.as(AttributeSyntax.self) else { continue }
            let source = attribute.attributeName.constExprSource
            let name = source.split(separator: ".").last.map(String.init) ?? source
            if !safeNames.contains(name) {
                return source
            }
        }
        return nil
    }
}

extension String {
    var constExprStringLiteral: String {
        var result = "\""
        for scalar in unicodeScalars {
            switch scalar.value {
            case 0x22:
                result += "\\\""
            case 0x5C:
                result += "\\\\"
            case 0x0A:
                result += "\\n"
            case 0x0D:
                result += "\\r"
            case 0x09:
                result += "\\t"
            case 0x00...0x1F, 0x7F:
                result += "\\u{\(String(scalar.value, radix: 16))}"
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        result += "\""
        return result
    }

    var constExprSemanticIdentifier: String {
        guard count >= 2, first == "`", last == "`" else { return self }
        return String(dropFirst().dropLast())
    }
}

struct ConstExprNominalContext {
    let ownerReference: String
    let localTypeNames: Set<String>

    func typeSource(for type: TypeSyntax) -> String {
        let rewriter = ConstExprNominalTypeRewriter(
            ownerReference: ownerReference,
            localTypeNames: localTypeNames
        )
        return rewriter.rewrite(type).constExprSource
    }
}

private final class ConstExprNominalTypeRewriter: SyntaxRewriter {
    let ownerReference: String
    let localTypeNames: Set<String>

    init(ownerReference: String, localTypeNames: Set<String>) {
        self.ownerReference = ownerReference
        self.localTypeNames = localTypeNames
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: IdentifierTypeSyntax) -> TypeSyntax {
        let name = node.name.constExprIdentifier
        if name == "Self" {
            return TypeSyntax(stringLiteral: ownerReference)
        }
        if localTypeNames.contains(name) {
            return TypeSyntax(stringLiteral: "\(ownerReference).\(node.constExprSource)")
        }
        return super.visit(node)
    }
}

struct ConstExprParameterModel {
    let label: String?
    let invocationLabel: String?
    let type: String
    let typeDescriptor: String
    let defaultExpression: String?

    init(
        label: String?,
        invocationLabel: String? = nil,
        type: String,
        typeDescriptor: String,
        defaultExpression: String?
    ) {
        self.label = label
        self.invocationLabel = invocationLabel ?? label
        self.type = type
        self.typeDescriptor = typeDescriptor
        self.defaultExpression = defaultExpression
    }
}

struct ConstExprCallableModel {
    let parameters: [ConstExprParameterModel]
    let resultType: String
    let resultTypeDescriptor: String
    let isThrowing: Bool
}

struct ConstExprModelError: Error {
    let message: String
}

struct ConstExprAdapterNames {
    let implementation: String
    let receiver: String
    let arguments: String
    let instance: String
    let defaultMask: String
    let values: [String]
    let decodedArguments: [String]

    init(parameterCount: Int, context: some MacroExpansionContext) {
        implementation = context.makeUniqueName("constExprImplementation").constExprSourceSafeGeneratedIdentifier
        receiver = context.makeUniqueName("constExprReceiver").constExprSourceSafeGeneratedIdentifier
        arguments = context.makeUniqueName("constExprArguments").constExprSourceSafeGeneratedIdentifier
        instance = context.makeUniqueName("constExprInstance").constExprSourceSafeGeneratedIdentifier
        defaultMask = context.makeUniqueName("constExprDefaultMask").constExprSourceSafeGeneratedIdentifier
        values = (0..<parameterCount).map {
            context.makeUniqueName("constExprValue\($0)").constExprSourceSafeGeneratedIdentifier
        }
        decodedArguments = (0..<parameterCount).map {
            context.makeUniqueName("constExprArgument\($0)").constExprSourceSafeGeneratedIdentifier
        }
    }
}

private enum ConstExprUnsupportedTypeKind {
    case function
    case opaque
    case parameterizedExistential
    case implicitlyUnwrappedOptional
    case inoutSpecifier
    case ownershipSpecifier(String)
    case attributed(String)
}

private final class ConstExprGenericArgumentVisitor: SyntaxVisitor {
    var found = false

    init() {
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: GenericArgumentClauseSyntax) -> SyntaxVisitorContinueKind {
        found = true
        return .skipChildren
    }
}

private final class ConstExprUnsupportedTypeVisitor: SyntaxVisitor {
    var unsupported: ConstExprUnsupportedTypeKind?

    init() {
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: FunctionTypeSyntax) -> SyntaxVisitorContinueKind {
        unsupported = unsupported ?? .function
        return .skipChildren
    }

    override func visit(_ node: SomeOrAnyTypeSyntax) -> SyntaxVisitorContinueKind {
        if node.someOrAnySpecifier.tokenKind == .keyword(.some) {
            unsupported = unsupported ?? .opaque
            return .skipChildren
        }
        let genericArguments = ConstExprGenericArgumentVisitor()
        genericArguments.walk(node.constraint)
        if genericArguments.found {
            unsupported = unsupported ?? .parameterizedExistential
            return .skipChildren
        }
        return .visitChildren
    }

    override func visit(_ node: ImplicitlyUnwrappedOptionalTypeSyntax) -> SyntaxVisitorContinueKind {
        unsupported = unsupported ?? .implicitlyUnwrappedOptional
        return .skipChildren
    }

    override func visit(_ node: AttributedTypeSyntax) -> SyntaxVisitorContinueKind {
        for specifier in node.specifiers {
            let text = specifier.constExprSource
            if text == "inout" {
                unsupported = unsupported ?? .inoutSpecifier
            } else {
                unsupported = unsupported ?? .ownershipSpecifier(text)
            }
        }
        for specifier in node.lateSpecifiers {
            unsupported = unsupported ?? .ownershipSpecifier(specifier.constExprSource)
        }
        if !node.attributes.isEmpty {
            let source = node.attributes.constExprSource
            unsupported = unsupported ?? (source.contains("@autoclosure")
                ? .attributed("@autoclosure")
                : .attributed(source))
        }
        return unsupported == nil ? .visitChildren : .skipChildren
    }
}

private final class ConstExprCallerLocationVisitor: SyntaxVisitor {
    var found = false

    init() {
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: MacroExpansionExprSyntax) -> SyntaxVisitorContinueKind {
        let names: Set<String> = [
            "file", "fileID", "filePath", "line", "column", "function", "isolation",
        ]
        if names.contains(node.macroName.constExprIdentifier) {
            found = true
            return .skipChildren
        }
        return .visitChildren
    }
}

enum ConstExprSyntaxSupport {
    static func selectorLabel(for labels: [String]) -> String {
        guard !labels.isEmpty else { return "__constExprSelector_0" }
        let encoded = labels.map { rawLabel in
            let label = rawLabel.constExprSemanticIdentifier
            return "\(label.unicodeScalars.count)_\(label)"
        }.joined(separator: "__")
        return "__constExprSelector_\(labels.count)_\(encoded)"
    }

    static func selectorLabel(for parameters: FunctionParameterListSyntax) -> String {
        selectorLabel(for: parameters.map { $0.firstName.constExprIdentifier })
    }

    static func synthesizedName(for token: TokenSyntax, suffix: String) -> String {
        token.constExprIdentifier + suffix
    }

    static func callableModel(
        parameters: FunctionParameterListSyntax,
        effectSpecifiers: FunctionEffectSpecifiersSyntax?,
        returnType: TypeSyntax?,
        genericParameterClause: GenericParameterClauseSyntax?,
        genericWhereClause: GenericWhereClauseSyntax?,
        nominalContext: ConstExprNominalContext? = nil
    ) -> Result<ConstExprCallableModel, ConstExprModelError> {
        if genericParameterClause != nil || genericWhereClause != nil {
            return .failure(.init(message: "generic declarations are not supported by @ConstExpr"))
        }
        if effectSpecifiers?.asyncSpecifier != nil {
            return .failure(.init(message: "async declarations are not supported by @ConstExpr"))
        }
        if effectSpecifiers?.throwsClause?.throwsSpecifier.text == "rethrows" {
            return .failure(.init(message: "rethrows declarations are not supported by @ConstExpr"))
        }
        if effectSpecifiers?.throwsClause?.type != nil {
            return .failure(.init(message: "typed throws declarations are not supported by @ConstExpr"))
        }

        let resultSyntax = returnType ?? TypeSyntax(stringLiteral: "Void")
        if let error = unsupportedTypeError(resultSyntax, role: "result") {
            return .failure(error)
        }
        let resultType = nominalContext?.typeSource(for: resultSyntax) ?? resultSyntax.constExprSource
        if resultType == "Void" || resultType == "()" || resultType == "Never" {
            return .failure(.init(message: "@ConstExpr callables must return a value"))
        }

        var models: [ConstExprParameterModel] = []
        var defaultCount = 0
        for parameter in parameters {
            if parameter.ellipsis != nil {
                return .failure(.init(message: "variadic parameters are not supported by @ConstExpr"))
            }
            if parameter.attributes.constExprSource.contains("@autoclosure") {
                return .failure(.init(message: "@autoclosure parameters are not supported by @ConstExpr"))
            }
            if let error = unsupportedTypeError(parameter.type, role: "parameter") {
                return .failure(error)
            }

            let defaultExpression = parameter.defaultValue?.value.constExprSource
            if let defaultValue = parameter.defaultValue?.value,
               containsCallerLocation(defaultValue)
            {
                return .failure(.init(message: "caller-location default arguments are not supported by @ConstExpr"))
            }
            if defaultExpression != nil { defaultCount += 1 }

            models.append(
                ConstExprParameterModel(
                    label: parameter.firstName.constExprIdentifier == "_"
                        ? nil
                        : parameter.firstName.constExprIdentifier,
                    invocationLabel: parameter.firstName.constExprIdentifier == "_"
                        ? nil
                        // Keywords are accepted unescaped in argument-label
                        // position; retaining declaration backticks emits a
                        // compiler warning (and breaks warnings-as-errors).
                        : parameter.firstName.constExprIdentifier,
                    type: nominalContext?.typeSource(for: parameter.type)
                        ?? parameter.type.constExprSource,
                    typeDescriptor: typeDescriptorSource(
                        for: parameter.type,
                        nominalContext: nominalContext
                    ),
                    defaultExpression: defaultExpression
                )
            )
        }
        if defaultCount > 8 {
            return .failure(.init(message: "@ConstExpr supports at most eight defaulted parameters"))
        }

        return .success(
            ConstExprCallableModel(
                parameters: models,
                resultType: resultType,
                resultTypeDescriptor: typeDescriptorSource(
                    for: resultSyntax,
                    nominalContext: nominalContext
                ),
                isThrowing: effectSpecifiers?.throwsClause != nil
            )
        )
    }

    static func validatedValueType(
        _ type: TypeSyntax,
        nominalContext: ConstExprNominalContext? = nil
    ) -> Result<String, ConstExprModelError> {
        if let error = unsupportedTypeError(type, role: "value") {
            return .failure(error)
        }
        let source = nominalContext?.typeSource(for: type) ?? type.constExprSource
        if source == "Void" || source == "()" || source == "Never" {
            return .failure(.init(message: "the value type must be representable"))
        }
        return .success(source)
    }

    static func containsCallerLocation(_ expression: ExprSyntax) -> Bool {
        let visitor = ConstExprCallerLocationVisitor()
        visitor.walk(expression)
        return visitor.found
    }

    private static func unsupportedTypeError(
        _ type: TypeSyntax,
        role: String
    ) -> ConstExprModelError? {
        let visitor = ConstExprUnsupportedTypeVisitor()
        visitor.walk(type)
        switch visitor.unsupported {
        case .function:
            return .init(message: role == "result"
                ? "function and opaque result types are not supported by @ConstExpr"
                : "function-typed \(role)s are not supported by @ConstExpr")
        case .opaque:
            return .init(message: role == "result"
                ? "function and opaque result types are not supported by @ConstExpr"
                : "opaque \(role) types are not supported by @ConstExpr")
        case .parameterizedExistential:
            return .init(
                message: "parameterized existential \(role) types require macOS 13 or newer and are not supported by @ConstExpr's macOS 11 deployment target"
            )
        case .implicitlyUnwrappedOptional:
            return .init(message: "implicitly unwrapped optional \(role) types are not supported by @ConstExpr")
        case .inoutSpecifier:
            return .init(message: "inout parameters are not supported by @ConstExpr")
        case .ownershipSpecifier(let specifier):
            return .init(message: "'\(specifier)' \(role) specifiers are not supported by @ConstExpr")
        case .attributed(let attribute):
            if attribute == "@autoclosure" {
                return .init(message: "@autoclosure parameters are not supported by @ConstExpr")
            }
            return .init(message: "attributed \(role) types are not supported by @ConstExpr")
        case nil:
            return nil
        }
    }

    static func functionType(for callable: ConstExprCallableModel) -> String {
        let parameters = callable.parameters.map(\.type).joined(separator: ", ")
        let throwing = callable.isThrowing ? " throws" : ""
        return "(\(parameters))\(throwing) -> \(callable.resultType)"
    }

    static func requiredDecodeStatements(
        for parameters: [ConstExprParameterModel],
        names: ConstExprAdapterNames,
        including indices: Set<Int>? = nil
    ) -> [String] {
        parameters.enumerated().compactMap { index, parameter in
            if let indices, !indices.contains(index) { return nil }
            return """
            guard \(names.arguments).indices.contains(\(index)), let \(names.values[index]) = \(names.arguments)[\(index)] else {
                throw _ConstExprRuntime.ValueError.malformedCollection("missing argument at index \(index)")
            }
            let \(names.decodedArguments[index]) = try \(names.values[index]).require((\(parameter.type)).self)
            """
        }
    }

    static func copiedDefaultDecodeStatements(
        for parameters: [ConstExprParameterModel],
        names: ConstExprAdapterNames
    ) -> [String] {
        parameters.enumerated().map { index, parameter in
            if let defaultExpression = parameter.defaultExpression {
                return """
                let \(names.decodedArguments[index]): \(parameter.type)
                if \(names.arguments).indices.contains(\(index)), let \(names.values[index]) = \(names.arguments)[\(index)] {
                    \(names.decodedArguments[index]) = try \(names.values[index]).require((\(parameter.type)).self)
                } else {
                    \(names.decodedArguments[index]) = (\(defaultExpression))
                }
                """
            }
            return requiredDecodeStatements(
                for: parameters,
                names: names,
                including: [index]
            )[0]
        }
    }

    static func nativeDefaultInvocationBody(
        callable: ConstExprCallableModel,
        names: ConstExprAdapterNames,
        invocation: (_ includedParameters: Set<Int>) -> String
    ) -> String {
        let defaultIndices = callable.parameters.indices.filter {
            callable.parameters[$0].defaultExpression != nil
        }
        let requiredIndices = Set(callable.parameters.indices).subtracting(defaultIndices)
        var statements = requiredDecodeStatements(
            for: callable.parameters,
            names: names,
            including: requiredIndices
        )

        guard !defaultIndices.isEmpty else {
            statements.append(
                "return _ConstExprRuntime.Value((\(invocation(Set(callable.parameters.indices)))) as Any, preservingStaticType: \(metatypeSource(for: callable.resultType)), sourceTypeName: \(sourceTypeNameSource(for: callable.resultType)), isStaticallyAnyObject: \(staticallyAnyObjectSource(for: callable.resultType)))"
            )
            return statements.joined(separator: "\n")
        }

        statements.append("var \(names.defaultMask) = 0")
        for (bit, index) in defaultIndices.enumerated() {
            statements.append("""
            if \(names.arguments).indices.contains(\(index)), \(names.arguments)[\(index)] != nil {
                \(names.defaultMask) |= \(1 << bit)
            }
            """)
        }
        statements.append("switch \(names.defaultMask) {")

        for mask in 0..<(1 << defaultIndices.count) {
            var included = requiredIndices
            for (bit, index) in defaultIndices.enumerated() where mask & (1 << bit) != 0 {
                included.insert(index)
            }
            let decodeDefaults = requiredDecodeStatements(
                for: callable.parameters,
                names: names,
                including: included.intersection(defaultIndices)
            ).joined(separator: "\n")
            let body = [
                decodeDefaults,
                "return _ConstExprRuntime.Value((\(invocation(included))) as Any, preservingStaticType: \(metatypeSource(for: callable.resultType)), sourceTypeName: \(sourceTypeNameSource(for: callable.resultType)), isStaticallyAnyObject: \(staticallyAnyObjectSource(for: callable.resultType)))",
            ]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            statements.append("case \(mask):\n\(indent(body, by: 4))")
        }
        statements.append("""
        default:
            throw _ConstExprRuntime.ValueError.malformedCollection("invalid default argument mask")
        }
        """)
        return statements.joined(separator: "\n")
    }

    static func indent(_ source: String, by count: Int) -> String {
        let prefix = String(repeating: " ", count: count)
        return source.split(separator: "\n", omittingEmptySubsequences: false)
            .map { prefix + $0 }
            .joined(separator: "\n")
    }

    static func callArguments(
        for parameters: [ConstExprParameterModel],
        names: ConstExprAdapterNames,
        including indices: Set<Int>? = nil
    ) -> String {
        parameters.indices.compactMap { index in
            if let indices, !indices.contains(index) { return nil }
            return names.decodedArguments[index]
        }.joined(separator: ", ")
    }

    static func labeledCallArguments(
        for parameters: [ConstExprParameterModel],
        names: ConstExprAdapterNames,
        including indices: Set<Int>? = nil
    ) -> String {
        parameters.indices.compactMap { index in
            if let indices, !indices.contains(index) { return nil }
            if let label = parameters[index].invocationLabel {
                return "\(label): \(names.decodedArguments[index])"
            }
            return names.decodedArguments[index]
        }.joined(separator: ", ")
    }

    static func labelsSource(for parameters: [ConstExprParameterModel]) -> String {
        "[" + parameters.map { parameter in
            parameter.label.map(\.constExprStringLiteral) ?? "nil"
        }.joined(separator: ", ") + "]"
    }

    static func typesSource(for parameters: [ConstExprParameterModel]) -> String {
        "[" + parameters.map { "(\($0.type)).self" }.joined(separator: ", ") + "]"
    }

    static func typeDescriptorsSource(for parameters: [ConstExprParameterModel]) -> String {
        "[" + parameters.map(\.typeDescriptor).joined(separator: ", ") + "]"
    }

    static func typeDescriptorSource(
        for type: TypeSyntax,
        nominalContext: ConstExprNominalContext? = nil
    ) -> String {
        if let optional = type.as(OptionalTypeSyntax.self) {
            return "_ConstExprRuntime.StaticTypeDescriptor.optional(\(typeDescriptorSource(for: optional.wrappedType, nominalContext: nominalContext)))"
        }
        if let arguments = standardGenericArguments(
            of: type,
            named: "Optional",
            arity: 1,
            nominalContext: nominalContext
        ) {
            return "_ConstExprRuntime.StaticTypeDescriptor.optional(\(typeDescriptorSource(for: arguments[0], nominalContext: nominalContext)))"
        }
        if let array = type.as(ArrayTypeSyntax.self) {
            return "_ConstExprRuntime.StaticTypeDescriptor.array(\(typeDescriptorSource(for: array.element, nominalContext: nominalContext)))"
        }
        if let arguments = standardGenericArguments(
            of: type,
            named: "Array",
            arity: 1,
            nominalContext: nominalContext
        ) {
            return "_ConstExprRuntime.StaticTypeDescriptor.array(\(typeDescriptorSource(for: arguments[0], nominalContext: nominalContext)))"
        }
        if let dictionary = type.as(DictionaryTypeSyntax.self) {
            return "_ConstExprRuntime.StaticTypeDescriptor.dictionary(key: \(typeDescriptorSource(for: dictionary.key, nominalContext: nominalContext)), value: \(typeDescriptorSource(for: dictionary.value, nominalContext: nominalContext)))"
        }
        if let arguments = standardGenericArguments(
            of: type,
            named: "Dictionary",
            arity: 2,
            nominalContext: nominalContext
        ) {
            return "_ConstExprRuntime.StaticTypeDescriptor.dictionary(key: \(typeDescriptorSource(for: arguments[0], nominalContext: nominalContext)), value: \(typeDescriptorSource(for: arguments[1], nominalContext: nominalContext)))"
        }
        if let tuple = type.as(TupleTypeSyntax.self) {
            if tuple.elements.count == 1, let element = tuple.elements.first {
                return typeDescriptorSource(for: element.type, nominalContext: nominalContext)
            }
            let elements = tuple.elements.map {
                typeDescriptorSource(for: $0.type, nominalContext: nominalContext)
            }.joined(separator: ", ")
            return "_ConstExprRuntime.StaticTypeDescriptor.tuple([\(elements)])"
        }

        let source = nominalContext?.typeSource(for: type) ?? type.constExprSource
        let existential = type.as(SomeOrAnyTypeSyntax.self).flatMap { syntax -> String? in
            guard syntax.someOrAnySpecifier.tokenKind == .keyword(.any) else { return nil }
            return nominalContext?.typeSource(for: syntax.constraint)
                ?? syntax.constraint.constExprSource
        }
        let acceptsSourceType = existential.map {
            "{ $0 is any (\($0)).Type }"
        } ?? "nil"
        return "_ConstExprRuntime.StaticTypeDescriptor.leaf(type: \(metatypeSource(for: source)), sourceName: \(source.constExprStringLiteral), isExistential: \(existential != nil), isClassBound: \(staticallyAnyObjectSource(for: source)), acceptsSourceType: \(acceptsSourceType))"
    }

    private static func standardGenericArguments(
        of type: TypeSyntax,
        named expectedName: String,
        arity: Int,
        nominalContext: ConstExprNominalContext?
    ) -> [TypeSyntax]? {
        let clause: GenericArgumentClauseSyntax?
        if let identifier = type.as(IdentifierTypeSyntax.self),
           identifier.name.constExprIdentifier == expectedName,
           nominalContext?.localTypeNames.contains(expectedName) != true
        {
            clause = identifier.genericArgumentClause
        } else if let member = type.as(MemberTypeSyntax.self),
                  member.name.constExprIdentifier == expectedName,
                  member.baseType.constExprSource == "Swift"
        {
            clause = member.genericArgumentClause
        } else {
            return nil
        }
        guard let clause, clause.arguments.count == arity else { return nil }
        var result: [TypeSyntax] = []
        for argument in clause.arguments {
            guard case .type(let argumentType) = argument.argument else { return nil }
            result.append(argumentType)
        }
        return result
    }

    static func metatypeSource(for type: String) -> String {
        "(\(type)).self"
    }

    static func sourceTypeNameSource(for type: String?) -> String {
        type?.constExprStringLiteral ?? "nil"
    }

    static func staticallyAnyObjectSource(for type: String) -> String {
        "_ConstExprRuntime.isStaticallyAnyObject(Swift.Optional<\(type)>.none)"
    }

    static func defaultedIndicesSource(for parameters: [ConstExprParameterModel]) -> String {
        "[" + parameters.enumerated().compactMap { index, parameter in
            parameter.defaultExpression == nil ? nil : String(index)
        }.joined(separator: ", ") + "]"
    }
}
