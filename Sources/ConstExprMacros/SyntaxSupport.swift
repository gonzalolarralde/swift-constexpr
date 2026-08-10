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
    var constExprExplicitAccessLevel: ConstExprAccessLevel? {
        for modifier in self where modifier.detail == nil {
            switch modifier.name.tokenKind {
            case .keyword(.open), .keyword(.public): return .public
            case .keyword(.package): return .package
            case .keyword(.fileprivate): return .fileprivate
            case .keyword(.private): return .private
            default: continue
            }
        }
        return nil
    }

    var constExprAccessLevel: ConstExprAccessLevel {
        constExprExplicitAccessLevel ?? .internal
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
    func constExprContainsAttribute(named requestedName: String) -> Bool {
        let visitor = ConstExprAttributePresenceVisitor(
            requestedName: requestedName
        )
        visitor.walk(self)
        return visitor.found
    }

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
            "ConstExprIgnored",
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
            "_disfavoredOverload",
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

private final class ConstExprAttributePresenceVisitor: SyntaxVisitor {
    let requestedName: String
    var found = false

    init(requestedName: String) {
        self.requestedName = requestedName
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: AttributeSyntax) -> SyntaxVisitorContinueKind {
        let source = node.attributeName.constExprSource
        if source == requestedName
            || source.split(separator: ".").last.map(String.init) == requestedName
        {
            found = true
        }
        return .skipChildren
    }
}

extension DeclSyntax {
    var constExprAttributes: AttributeListSyntax {
        if let declaration = `as`(FunctionDeclSyntax.self) { return declaration.attributes }
        if let declaration = `as`(VariableDeclSyntax.self) { return declaration.attributes }
        if let declaration = `as`(InitializerDeclSyntax.self) { return declaration.attributes }
        if let declaration = `as`(SubscriptDeclSyntax.self) { return declaration.attributes }
        if let declaration = `as`(StructDeclSyntax.self) { return declaration.attributes }
        if let declaration = `as`(ClassDeclSyntax.self) { return declaration.attributes }
        if let declaration = `as`(EnumDeclSyntax.self) { return declaration.attributes }
        if let declaration = `as`(EnumCaseDeclSyntax.self) { return declaration.attributes }
        return []
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
    let defaultIsSelfContainedLiteral: Bool

    init(
        label: String?,
        invocationLabel: String? = nil,
        type: String,
        typeDescriptor: String,
        defaultExpression: String?,
        defaultIsSelfContainedLiteral: Bool = false
    ) {
        self.label = label
        self.invocationLabel = invocationLabel ?? label
        self.type = type
        self.typeDescriptor = typeDescriptor
        self.defaultExpression = defaultExpression
        self.defaultIsSelfContainedLiteral = defaultIsSelfContainedLiteral
    }
}

struct ConstExprCallableModel {
    let parameters: [ConstExprParameterModel]
    let resultType: String
    let resultTypeDescriptor: String
    let isThrowing: Bool

    var defaultCount: Int {
        parameters.count { $0.defaultExpression != nil }
    }

    var defaultsAreSelfContainedLiterals: Bool {
        parameters.allSatisfy {
            $0.defaultExpression == nil || $0.defaultIsSelfContainedLiteral
        }
    }

    var requiresManualDefaultAdapter: Bool {
        defaultCount > 8 && !defaultsAreSelfContainedLiterals
    }
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

enum ConstExprUnsupportedTypeKind {
    case function
    case opaque
    case parameterizedExistential
    case implicitlyUnwrappedOptional
    case inoutSpecifier
    case ownershipSpecifier(String)
    case attributed(String)
}

final class ConstExprGenericArgumentVisitor: SyntaxVisitor {
    var found = false

    init() {
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: GenericArgumentClauseSyntax) -> SyntaxVisitorContinueKind {
        found = true
        return .skipChildren
    }
}

final class ConstExprUnsupportedTypeVisitor: SyntaxVisitor {
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

final class ConstExprCallerLocationVisitor: SyntaxVisitor {
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

enum ConstExprSyntaxSupport {}
