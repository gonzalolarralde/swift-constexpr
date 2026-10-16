import ConstExprMacroImplementation
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacroExpansion
import SwiftSyntaxMacros

struct RegistryDiscoveryRecord {
    let path: String
    let entry: ConstExprRegistrationDiscovery.Entry
}

final class RegistrySourceScanner: SyntaxVisitor {
    let path: String
    let converter: SourceLocationConverter
    let sameModule: Bool
    var issues: [String] = []
    var records: [RegistryDiscoveryRecord] = []

    init(path: String, tree: SourceFileSyntax, sameModule: Bool) {
        self.path = path
        self.converter = SourceLocationConverter(fileName: path, tree: tree)
        self.sameModule = sameModule
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: AttributeSyntax) -> SyntaxVisitorContinueKind {
        let name = node.attributeName.trimmedDescription.split(separator: ".").last.map(String.init)
        guard name == "ConstExpr" || name == "ConstExprMembers" else { return .skipChildren }
        var parent = node.parent
        while let current = parent, !current.is(DeclSyntax.self) { parent = current.parent }
        guard let declaration = parent?.as(DeclSyntax.self) else {
            issue("cannot find the declaration owning this annotation", at: Syntax(node))
            return .skipChildren
        }
        if hasConditionalAncestor(Syntax(node)) {
            issue("conditional ConstExpr annotations need a manually configured registry; the command cannot assume the source and macro targets share build flags", at: Syntax(node))
            return .skipChildren
        }
        let conditionals = DeclarationConditionals(viewMode: .sourceAccurate)
        conditionals.walk(declaration)
        if conditionals.found {
            issue("conditional members or attributes inside an annotated declaration need an explicitly configured registry", at: Syntax(node))
            return .skipChildren
        }
        if hasGatedAncestor(Syntax(declaration)) {
            issue("an availability- or SPI-gated enclosing type needs a manually guarded registry", at: Syntax(node))
            return .skipChildren
        }
        let context = BasicMacroExpansionContext(lexicalContext: declaration.allMacroLexicalContexts())
        do {
            let entries = try ConstExprRegistrationDiscovery.entries(
                for: declaration, attribute: node, sameModule: sameModule, in: context
            )
            records += entries.map { RegistryDiscoveryRecord(path: path, entry: $0) }
        } catch {
            issue("registration discovery failed: \(error)", at: Syntax(node))
        }
        for diagnostic in context.diagnostics where diagnostic.diagMessage.severity == .error {
            issue(diagnostic.message, at: Syntax(node))
        }
        return .skipChildren
    }

    private func hasGatedAncestor(_ node: Syntax) -> Bool {
        var current = node.parent
        while let parent = current {
            let attributes: AttributeListSyntax?
            if let type = parent.as(StructDeclSyntax.self) { attributes = type.attributes }
            else if let type = parent.as(ClassDeclSyntax.self) { attributes = type.attributes }
            else if let type = parent.as(EnumDeclSyntax.self) { attributes = type.attributes }
            else if let type = parent.as(ExtensionDeclSyntax.self) { attributes = type.attributes }
            else { attributes = nil }
            if let attributes, attributes.contains(where: { element in
                guard let attribute = element.as(AttributeSyntax.self) else { return false }
                let name = attribute.attributeName.trimmedDescription.split(separator: ".").last.map(String.init) ?? ""
                return name == "available" || name == "_spi"
            }) { return true }
            current = parent.parent
        }
        return false
    }

    private func issue(_ message: String, at node: Syntax) {
        let location = converter.location(for: node.positionAfterSkippingLeadingTrivia)
        issues.append("\(path):\(location.line):\(location.column): error: \(message)")
    }
}

func hasConditionalAncestor(_ node: Syntax) -> Bool {
    var current = node.parent
    while let parent = current {
        if parent.is(IfConfigDeclSyntax.self) { return true }
        current = parent.parent
    }
    return false
}

/// Conditional implementation code inside a function is ordinary native Swift;
/// only conditions affecting the declarations/providers concern discovery.
private final class DeclarationConditionals: SyntaxVisitor {
    var found = false
    override func visit(_ node: IfConfigDeclSyntax) -> SyntaxVisitorContinueKind {
        found = true
        return .skipChildren
    }
    override func visit(_ node: CodeBlockSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
    override func visit(_ node: AccessorBlockSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
}
