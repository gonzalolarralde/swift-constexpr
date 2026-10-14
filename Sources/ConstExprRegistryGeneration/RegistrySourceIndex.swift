import SwiftParser
import SwiftSyntax
import SwiftSyntaxBuilder

/// Qualifies source-module names so selectors cannot bind to an unrelated
/// imported declaration with the same short name. Swift still type-checks the
/// emitted selectors and overload casts during the normal macro-target build.
final class RegistrySourceIndex: SyntaxVisitor {
    let module: String
    var types: Set<String> = []
    var globals: Set<String> = []
    var imports: Set<String> = []
    var issues: [String] = []

    init(module: String) { self.module = module; super.init(viewMode: .sourceAccurate) }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind { record(node.name, node: Syntax(node)); return .visitChildren }
    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind { record(node.name, node: Syntax(node)); return .visitChildren }
    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind { record(node.name, node: Syntax(node)); return .visitChildren }
    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind { record(node.name, node: Syntax(node)); return .visitChildren }
    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind { record(node.name, node: Syntax(node)); return .visitChildren }
    override func visit(_ node: TypeAliasDeclSyntax) -> SyntaxVisitorContinueKind { record(node.name, node: Syntax(node)); return .skipChildren }
    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        if enclosingTypeNames(Syntax(node)).isEmpty { globals.insert(node.name.trimmedDescription) }
        return .skipChildren
    }
    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        if enclosingTypeNames(Syntax(node)).isEmpty {
            for binding in node.bindings {
                if let name = binding.pattern.as(IdentifierPatternSyntax.self) { globals.insert(name.identifier.trimmedDescription) }
            }
        }
        return .skipChildren
    }
    override func visit(_ node: ImportDeclSyntax) -> SyntaxVisitorContinueKind {
        if hasConditionalAncestor(Syntax(node)) {
            issues.append("conditional imports in the selected module need an explicitly configured registry")
        } else {
            let kind = node.importKindSpecifier.map { $0.text + " " } ?? ""
            imports.insert("import " + kind + node.path.trimmedDescription)
        }
        return .skipChildren
    }

    private func record(_ name: TokenSyntax, node: Syntax) {
        types.insert((enclosingTypeNames(node) + [name.trimmedDescription]).joined(separator: "."))
    }

    func qualifyType(_ source: String, owner: String?) -> String {
        let type = TypeSyntax(stringLiteral: source)
        return Qualifier(index: self, owner: owner).rewrite(type).trimmedDescription
    }

    func qualifyExpression(_ source: String, owner: String?) -> String {
        let tree = Parser.parse(source: source)
        return Qualifier(index: self, owner: owner).rewrite(tree).trimmedDescription
    }

    private func typeReference(_ name: String, owner: String?) -> String? {
        guard name != module else { return nil }
        var scope = owner?.split(separator: ".").map(String.init) ?? []
        if scope.first == module { scope.removeFirst() }
        while !scope.isEmpty {
            let candidate = (scope + [name]).joined(separator: ".")
            if types.contains(candidate) { return module + "." + candidate }
            scope.removeLast()
        }
        return types.contains(name) ? module + "." + name : nil
    }

    private final class Qualifier: SyntaxRewriter {
        let index: RegistrySourceIndex
        let owner: String?
        init(index: RegistrySourceIndex, owner: String?) {
            self.index = index; self.owner = owner
            super.init(viewMode: .sourceAccurate)
        }
        override func visit(_ node: IdentifierTypeSyntax) -> TypeSyntax {
            guard let name = index.typeReference(node.name.trimmedDescription, owner: owner) else { return super.visit(node) }
            let rewritten = super.visit(node)
            let suffix = rewritten.as(IdentifierTypeSyntax.self)?.genericArgumentClause?.trimmedDescription ?? ""
            return TypeSyntax(stringLiteral: name + suffix).with(\.leadingTrivia, node.leadingTrivia).with(\.trailingTrivia, node.trailingTrivia)
        }
        override func visit(_ node: DeclReferenceExprSyntax) -> ExprSyntax {
            let name = node.baseName.trimmedDescription
            let qualified = index.typeReference(name, owner: owner)
                ?? (index.globals.contains(name) ? index.module + "." + name : nil)
            guard let qualified else { return super.visit(node) }
            return ExprSyntax(stringLiteral: qualified + (node.argumentNames?.trimmedDescription ?? ""))
                .with(\.leadingTrivia, node.leadingTrivia).with(\.trailingTrivia, node.trailingTrivia)
        }
    }
}

private func enclosingTypeNames(_ node: Syntax) -> [String] {
    var names: [String] = []
    var current = node.parent
    while let parent = current {
        if let type = parent.as(StructDeclSyntax.self) { names.append(type.name.trimmedDescription) }
        else if let type = parent.as(ClassDeclSyntax.self) { names.append(type.name.trimmedDescription) }
        else if let type = parent.as(EnumDeclSyntax.self) { names.append(type.name.trimmedDescription) }
        else if let type = parent.as(ActorDeclSyntax.self) { names.append(type.name.trimmedDescription) }
        else if let type = parent.as(ProtocolDeclSyntax.self) { names.append(type.name.trimmedDescription) }
        else if let type = parent.as(ExtensionDeclSyntax.self) { names.append(type.extendedType.trimmedDescription) }
        current = parent.parent
    }
    return names.reversed()
}
