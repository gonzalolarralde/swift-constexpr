import ConstExprEvaluation
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// Resolves only known Boolean selection. Unknown conditions retain the original
/// result-builder closure, so no call in an uncertain branch runs on the host.
/// Selected blocks become straight-line source with hygienic branch-local names.
final class ConstExprBuilderBranchLowering {
    private let builder: String
    private let runner: ConstExprRunner
    private let context: any MacroExpansionContext
    private var lines: [String] = []
    private var generatedBindings: Set<String> = []

    init(builder: String, runner: ConstExprRunner, context: any MacroExpansionContext) {
        self.builder = builder
        self.runner = runner
        self.context = context
    }

    func lower(_ closure: ClosureExprSyntax) -> (text: String, result: String, generatedBindings: Set<String>)? {
        guard closure.signature == nil else { return nil }
        let visitor = UnsupportedSyntax(viewMode: .sourceAccurate)
        visitor.walk(closure.statements)
        guard !visitor.found,
              let partial = lowerBlock(closure.statements, names: [:], nested: false)
        else { return nil }
        let result = bind("\(builder).buildFinalResult(\(partial))", stem: "constExprBuilderResult")
        return (lines.joined(separator: "\n"), result, generatedBindings)
    }

    private func lowerBlock(
        _ statements: CodeBlockItemListSyntax,
        names initialNames: [String: String],
        nested: Bool
    ) -> String? {
        var names = initialNames
        var declarations: Set<String> = []
        var components: [String] = []
        let builderRoot = builder.split(separator: ".").first.map { normalized(String($0)) }
        for item in statements {
            switch item.item {
            case .decl(let declaration):
                guard var variable = declaration.as(VariableDeclSyntax.self),
                      variable.bindingSpecifier.tokenKind == .keyword(.let),
                      variable.attributes.isEmpty, variable.modifiers.isEmpty
                else { return nil }
                var bindings: [PatternBindingSyntax] = []
                for var binding in variable.bindings {
                    guard var pattern = binding.pattern.as(IdentifierPatternSyntax.self),
                          var initializer = binding.initializer, binding.accessorBlock == nil
                    else { return nil }
                    let original = normalized(pattern.identifier.text)
                    guard original != builderRoot, declarations.insert(original).inserted else { return nil }
                    initializer.value = renamed(initializer.value, names: names)
                    binding.initializer = initializer
                    if nested {
                        let replacement = context.makeUniqueName("constExprLocal").text
                        names[original] = replacement
                        pattern.identifier = .identifier(replacement)
                            .with(\.leadingTrivia, pattern.identifier.leadingTrivia)
                            .with(\.trailingTrivia, pattern.identifier.trailingTrivia)
                        binding.pattern = PatternSyntax(pattern)
                    }
                    bindings.append(binding)
                }
                variable.bindings = PatternBindingListSyntax(bindings)
                lines.append(variable.trimmedDescription)
            case .expr(let expression):
                if let selection = expression.as(IfExprSyntax.self) {
                    guard let component = lowerSelection(selection, names: names) else { return nil }
                    components.append(component)
                } else {
                    guard !expression.is(SwitchExprSyntax.self) else { return nil }
                    let expression = renamed(expression, names: names)
                    components.append(bind("\(builder).buildExpression(\(expression.trimmedDescription))"))
                }
            case .stmt(let statement):
                guard let selection = statement.as(ExpressionStmtSyntax.self)?.expression.as(IfExprSyntax.self),
                      let component = lowerSelection(selection, names: names)
                else { return nil }
                components.append(component)
            }
        }
        // SE-0348 evaluates every component before accumulating the block.
        guard let first = components.first else { return bind("\(builder).buildBlock()") }
        var partial = bind("\(builder).buildPartialBlock(first: \(first))")
        for next in components.dropFirst() {
            partial = bind("\(builder).buildPartialBlock(accumulated: \(partial), next: \(next))")
        }
        return partial
    }

    private func lowerSelection(_ selection: IfExprSyntax, names: [String: String]) -> String? {
        var cases: [(condition: ExprSyntax?, body: CodeBlockItemListSyntax)] = []
        var current = selection
        var hasElse = false
        while true {
            guard current.conditions.count == 1,
                  let condition = current.conditions.first?.condition.as(ExprSyntax.self)
            else { return nil }
            cases.append((condition, current.body.statements))
            if let next = current.elseBody?.as(IfExprSyntax.self) {
                current = next
            } else {
                if let body = current.elseBody?.as(CodeBlockSyntax.self) {
                    cases.append((nil, body.statements))
                    hasElse = true
                }
                break
            }
        }
        var selected: Int?
        for (index, item) in cases.enumerated() {
            guard let condition = item.condition else { selected = index; break }
            let conditionName = context.makeUniqueName("constExprCondition").text
            let conditionSource = renamed(condition, names: names).trimmedDescription
            let source = (lines + ["let \(conditionName) = \(conditionSource)"]).joined(separator: "\n")
            guard case .success(let value) = runner.evaluateValue(
                source: source, binding: conditionName, policy: .permissive
            ), value.staticType == Bool.self,
               let flag = try? value.require(Bool.self)
            else { return nil }
            if flag { selected = index; break }
        }
        guard let selected else {
            return hasElse ? nil : bind("\(builder).buildOptional(nil)")
        }
        guard let partial = lowerBlock(cases[selected].body, names: names, nested: true) else { return nil }
        let injected = inject(partial, index: selected, count: cases.count)
        return bind(hasElse ? injected : "\(builder).buildOptional(\(injected))")
    }

    /// Swift's balanced injection tree groups the largest complete left subtree.
    /// Compiler-differential tests cover non-power-of-two else-if chains.
    private func inject(_ value: String, index: Int, count: Int) -> String {
        guard count > 1 else { return value }
        var split = 1
        while split * 2 < count { split *= 2 }
        if index < split {
            return "\(builder).buildEither(first: \(inject(value, index: index, count: split)))"
        }
        return "\(builder).buildEither(second: \(inject(value, index: index - split, count: count - split)))"
    }

    private func bind(_ expression: String, stem: String = "constExprComponent") -> String {
        let name = context.makeUniqueName(stem).text
        generatedBindings.insert(name)
        lines.append("let \(name) = \(expression)")
        return name
    }

    private func renamed(_ expression: ExprSyntax, names: [String: String]) -> ExprSyntax {
        References(names: names).rewrite(expression).cast(ExprSyntax.self)
    }

    private func normalized(_ name: String) -> String { name.filter { $0 != "`" } }

    private final class References: SyntaxRewriter {
        let names: [String: String]
        init(names: [String: String]) { self.names = names; super.init(viewMode: .sourceAccurate) }

        override func visit(_ node: DeclReferenceExprSyntax) -> ExprSyntax {
            guard let name = names[node.baseName.text.filter({ $0 != "`" })] else { return ExprSyntax(node) }
            var result = node
            result.baseName = .identifier(name)
                .with(\.leadingTrivia, node.baseName.leadingTrivia)
                .with(\.trailingTrivia, node.baseName.trailingTrivia)
            return ExprSyntax(result)
        }

        override func visit(_ node: MemberAccessExprSyntax) -> ExprSyntax {
            var result = node
            if let base = node.base { result.base = rewrite(base).cast(ExprSyntax.self) }
            return ExprSyntax(result)
        }
    }

    private final class UnsupportedSyntax: SyntaxVisitor {
        var found = false
        override func visit(_ node: TryExprSyntax) -> SyntaxVisitorContinueKind { reject() }
        override func visit(_ node: AwaitExprSyntax) -> SyntaxVisitorContinueKind { reject() }
        override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind { reject() }
        override func visit(_ node: MacroExpansionExprSyntax) -> SyntaxVisitorContinueKind { reject() }
        private func reject() -> SyntaxVisitorContinueKind { found = true; return .skipChildren }
    }
}
