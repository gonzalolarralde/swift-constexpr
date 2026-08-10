import SwiftOperators
import SwiftParser
import SwiftParserDiagnostics
import SwiftSyntax

/// Rewrites every expression that can be proven constant using the supplied
/// registrations. Unsupported source is retained verbatim wherever possible.
public struct ConstExprRunner: Sendable {
    public let registry: ConstExprRegistry
    public let options: ConstExprRewriteOptions

    public init(
        registry: ConstExprRegistry,
        options: ConstExprRewriteOptions = .init()
    ) {
        self.registry = registry
        self.options = options
    }

    public func rewrite(
        source: String,
        fileName: String = "<memory>"
    ) -> ConstExprRewriteResult {
        let hasByteOrderMark = source.first == "\u{FEFF}"
        let parsed = Parser.parse(source: source)
        let parseDiagnostics = ParseDiagnosticsGenerator.diagnostics(for: parsed)
        let parseConverter = SourceLocationConverter(fileName: fileName, tree: parsed)

        var diagnostics = parseDiagnostics.map { diagnostic -> ConstExprDiagnostic in
            let location = parseConverter.location(for: diagnostic.position)
            let severity: ConstExprDiagnostic.Severity
            switch diagnostic.diagMessage.severity {
            case .error: severity = .error
            case .warning: severity = .warning
            case .note: severity = .note
            case .remark: severity = .note
            }
            return ConstExprDiagnostic(
                severity: severity,
                code: "parse-error",
                message: diagnostic.message,
                fileName: fileName,
                line: location.line,
                column: location.column,
                offset: diagnostic.position.utf8Offset
            )
        }

        diagnostics.append(contentsOf: registry.validationDiagnostics.map { diagnostic in
            ConstExprDiagnostic(
                severity: diagnostic.severity,
                code: diagnostic.code,
                message: diagnostic.message,
                fileName: fileName,
                line: diagnostic.line,
                column: diagnostic.column,
                offset: diagnostic.offset
            )
        })

        // SwiftParser represents malformed constructs using recovered nodes.
        // Executing registrations against those nodes could both run user code
        // and silently "repair" the source into a different program.
        if diagnostics.contains(where: { $0.code == "parse-error" && $0.severity == .error }) {
            diagnostics.sort {
                ($0.line, $0.column, $0.code, $0.message)
                    < ($1.line, $1.column, $1.code, $1.message)
            }
            return ConstExprRewriteResult(source: source, diagnostics: diagnostics)
        }

        var operatorTable = OperatorTable.standardOperators
        var operatorErrors: [OperatorError] = []
        operatorTable.addSourceFile(parsed) { operatorErrors.append($0) }
        let operatorRegistrationDiagnostics = installRegisteredOperatorDeclarations(
            in: &operatorTable,
            sourceFile: parsed,
            fileName: fileName
        )
        diagnostics.append(contentsOf: operatorRegistrationDiagnostics)
        let foldedSyntax = operatorTable.foldAll(parsed) { operatorErrors.append($0) }
        var seenOperatorErrors: Set<String> = []
        for error in operatorErrors {
            let diagnostic = error.asDiagnostic
            let location = parseConverter.location(for: diagnostic.position)
            let key = "\(location.line):\(location.column):\(diagnostic.message)"
            guard seenOperatorErrors.insert(key).inserted else { continue }
            diagnostics.append(
                ConstExprDiagnostic(
                    severity: .error,
                    code: "operator-error",
                    message: diagnostic.message,
                    fileName: fileName,
                    line: location.line,
                    column: location.column,
                    offset: diagnostic.position.utf8Offset
                )
            )
        }
        if !operatorErrors.isEmpty
            || operatorRegistrationDiagnostics.contains(where: { $0.severity == .error })
        {
            diagnostics.sort {
                ($0.line, $0.column, $0.code, $0.message)
                    < ($1.line, $1.column, $1.code, $1.message)
            }
            return ConstExprRewriteResult(source: source, diagnostics: diagnostics)
        }
        let folded = foldedSyntax.cast(SourceFileSyntax.self)

        let evaluator = ConstExprSourceEvaluator(
            registry: registry,
            maximumNodeCount: max(1, options.maximumEvaluationSteps),
            maximumDepth: max(1, options.maximumRecursionDepth)
        )
        let rewrittenSyntax = ConstExprSourceRewriter(evaluator: evaluator).rewrite(folded)
        let rewritten = rewrittenSyntax.cast(SourceFileSyntax.self)
        let converter = SourceLocationConverter(fileName: fileName, tree: folded)

        diagnostics.append(contentsOf: evaluator.events.map { event in
            let location = converter.location(for: event.position)
            let severity: ConstExprDiagnostic.Severity
            switch event.severity {
            case .note: severity = .note
            case .warning: severity = .warning
            case .error: severity = .error
            }
            return ConstExprDiagnostic(
                severity: severity,
                code: event.code,
                message: event.message,
                fileName: fileName,
                line: location.line,
                column: location.column,
                offset: event.position.utf8Offset
            )
        })
        diagnostics.sort {
            ($0.line, $0.column, $0.code, $0.message)
                < ($1.line, $1.column, $1.code, $1.message)
        }

        let rewrittenSource = rewritten.description
        let output = hasByteOrderMark && rewrittenSource.first != "\u{FEFF}"
            ? "\u{FEFF}" + rewrittenSource
            : rewrittenSource
        return ConstExprRewriteResult(source: output, diagnostics: diagnostics)
    }

    /// Compatibility convenience for callers interested only in rewritten
    /// source. Diagnostics remain available through ``rewrite(source:fileName:)``.
    public func run(input: String) -> String {
        rewrite(source: input).source
    }

    private func installRegisteredOperatorDeclarations(
        in operatorTable: inout OperatorTable,
        sourceFile: SourceFileSyntax,
        fileName: String
    ) -> [ConstExprDiagnostic] {
        let collisionIDs = Set(
            Dictionary(grouping: registry.registrations, by: \.declarationID)
                .filter { $0.value.count > 1 }
                .keys
        )
        let registrations = registry.registrations.filter {
            $0.isValid && !collisionIDs.contains($0.declarationID)
        }
        let declaredOperators = SourceOperatorCollector.collect(from: sourceFile)
        let precedenceAssociativities = PrecedenceGroupAssociativityCollector.collect(
            from: operatorTable.description
        )
        let grouped = Dictionary(grouping: registrations.compactMap(RegisteredOperator.init)) {
            $0.key
        }
        var diagnostics: [ConstExprDiagnostic] = []

        for key in grouped.keys.sorted() {
            guard let operators = grouped[key] else { continue }
            // A real source declaration or the standard table is the
            // authoritative grouping contract. Registration metadata is used
            // only to synthesize a declaration for an otherwise unknown key.
            guard !declaredOperators.contains(key),
                !key.isInstalled(in: operatorTable)
            else { continue }
            let precedenceGroups = Set(operators.compactMap(\.metadata.precedenceGroup))
            let associativities = Set(operators.compactMap(\.metadata.associativity))
            guard precedenceGroups.count <= 1, associativities.count <= 1 else {
                diagnostics.append(
                    ConstExprDiagnostic(
                        severity: .error,
                        code: "operator-registration-conflict",
                        message: "registered \(key.fixity) operator '\(key.symbol)' has conflicting precedence or associativity metadata",
                        fileName: fileName,
                        line: 1,
                        column: 1
                    )
                )
                continue
            }
            let registeredGroup = precedenceGroups.first
            let registeredAssociativity = associativities.first
            let effectiveGroup = registeredGroup
            if key.fixity == "infix", let registeredAssociativity {
                guard let authoritativeAssociativity = effectiveGroup.flatMap({
                    precedenceAssociativities[$0]
                }) ?? (effectiveGroup == nil
                    ? ConstExprOperatorAssociativity.none
                    : nil) else {
                    diagnostics.append(operatorMetadataConflict(
                        key,
                        message: "cannot verify associativity for unknown precedence group '\(effectiveGroup!)'",
                        fileName: fileName
                    ))
                    continue
                }
                guard registeredAssociativity == authoritativeAssociativity else {
                    diagnostics.append(operatorMetadataConflict(
                        key,
                        message: "registered associativity '\(registeredAssociativity.rawValue)' does not match precedence group '\(effectiveGroup ?? "none")' associativity '\(authoritativeAssociativity.rawValue)'",
                        fileName: fileName
                    ))
                    continue
                }
            }
            let declarationSource: String
            if key.fixity == "infix", let effectiveGroup {
                declarationSource = "infix operator \(key.symbol): \(effectiveGroup)"
            } else {
                declarationSource = "\(key.fixity) operator \(key.symbol)"
            }
            let synthetic = Parser.parse(source: declarationSource)
            let parseDiagnostics = ParseDiagnosticsGenerator.diagnostics(for: synthetic)
            if let parseError = parseDiagnostics.first(where: {
                $0.diagMessage.severity == .error
            }) {
                diagnostics.append(
                    ConstExprDiagnostic(
                        severity: .error,
                        code: "operator-registration-error",
                        message: "cannot synthesize declaration for registered \(key.fixity) operator '\(key.symbol)': \(parseError.message)",
                        fileName: fileName,
                        line: 1,
                        column: 1
                    )
                )
                continue
            }

            guard synthetic.statements.count == 1,
                  let declaration = synthetic.statements.first?.item.as(OperatorDeclSyntax.self),
                  declaration.fixitySpecifier.text == key.fixity,
                  declaration.name.text == key.symbol
            else {
                diagnostics.append(
                    ConstExprDiagnostic(
                        severity: .error,
                        code: "operator-registration-error",
                        message: "cannot synthesize declaration for registered \(key.fixity) operator '\(key.symbol)': the symbol does not form exactly one operator declaration",
                        fileName: fileName,
                        line: 1,
                        column: 1
                    )
                )
                continue
            }

            var syntheticErrors: [OperatorError] = []
            operatorTable.addSourceFile(synthetic) { syntheticErrors.append($0) }
            if let error = syntheticErrors.first {
                diagnostics.append(
                    ConstExprDiagnostic(
                        severity: .error,
                        code: "operator-registration-error",
                        message: "cannot install declaration for registered \(key.fixity) operator '\(key.symbol)': \(error.asDiagnostic.message)",
                        fileName: fileName,
                        line: 1,
                        column: 1
                    )
                )
            }
        }
        return diagnostics
    }

    private func operatorMetadataConflict(
        _ key: RegisteredOperatorKey,
        message: String,
        fileName: String
    ) -> ConstExprDiagnostic {
        ConstExprDiagnostic(
            severity: .error,
            code: "operator-registration-conflict",
            message: "registered \(key.fixity) operator '\(key.symbol)' has inconsistent metadata: \(message)",
            fileName: fileName,
            line: 1,
            column: 1
        )
    }
}

private struct RegisteredOperatorKey: Hashable, Comparable {
    var fixity: String
    var symbol: String

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.fixity, lhs.symbol) < (rhs.fixity, rhs.symbol)
    }

    func isInstalled(in operatorTable: OperatorTable) -> Bool {
        switch fixity {
        case "prefix": return operatorTable.prefixOperator(named: symbol) != nil
        case "infix": return operatorTable.infixOperator(named: symbol) != nil
        case "postfix": return operatorTable.postfixOperator(named: symbol) != nil
        default: return false
        }
    }

}

private struct RegisteredOperatorMetadata: Hashable {
    var precedenceGroup: String?
    var associativity: ConstExprOperatorAssociativity?
}

private struct RegisteredOperator {
    var key: RegisteredOperatorKey
    var metadata: RegisteredOperatorMetadata

    init?(_ registration: ConstExprRegistration) {
        let fixity: String
        switch registration.kind {
        case .prefixOperator: fixity = "prefix"
        case .infixOperator: fixity = "infix"
        case .postfixOperator: fixity = "postfix"
        default: return nil
        }
        key = RegisteredOperatorKey(fixity: fixity, symbol: registration.name)
        if registration.kind == .infixOperator {
            metadata = RegisteredOperatorMetadata(
                precedenceGroup: registration.precedenceGroup,
                associativity: registration.associativity
            )
        } else {
            metadata = RegisteredOperatorMetadata(
                precedenceGroup: nil,
                associativity: nil
            )
        }
    }
}

private final class SourceOperatorCollector: SyntaxVisitor {
    private(set) var operators: Set<RegisteredOperatorKey> = []

    private init() {
        super.init(viewMode: .sourceAccurate)
    }

    static func collect(from sourceFile: SourceFileSyntax) -> Set<RegisteredOperatorKey> {
        let collector = SourceOperatorCollector()
        collector.walk(sourceFile)
        return collector.operators
    }

    override func visit(_ node: OperatorDeclSyntax) -> SyntaxVisitorContinueKind {
        operators.insert(
            RegisteredOperatorKey(
                fixity: node.fixitySpecifier.text,
                symbol: node.name.text
            )
        )
        return .skipChildren
    }
}

private final class PrecedenceGroupAssociativityCollector: SyntaxVisitor {
    private(set) var associativities: [String: ConstExprOperatorAssociativity] = [:]

    private init() {
        super.init(viewMode: .sourceAccurate)
    }

    static func collect(from source: String) -> [String: ConstExprOperatorAssociativity] {
        let collector = PrecedenceGroupAssociativityCollector()
        collector.walk(Parser.parse(source: source))
        return collector.associativities
    }

    override func visit(_ node: PrecedenceGroupDeclSyntax) -> SyntaxVisitorContinueKind {
        var value = ConstExprOperatorAssociativity.none
        for attribute in node.groupAttributes {
            guard case .precedenceGroupAssociativity(let syntax) = attribute else { continue }
            switch syntax.value.tokenKind {
            case .keyword(.left): value = .left
            case .keyword(.right): value = .right
            default: value = .none
            }
        }
        associativities[node.name.text] = value
        return .skipChildren
    }
}

private final class ConstExprSourceRewriter: SyntaxRewriter {
    let evaluator: ConstExprSourceEvaluator
    private var suppressBindingPropagation = 0
    private var suppressRegisteredCalls = 0
    private var expectedReturnTypes: [String?] = []
    private var implicitReturnTypes: [SyntaxIdentifier: String] = [:]
    private var resultBuilderFunctionNames: Set<String> = []
    private var requireExplicitLiteralContext = 0
    private var memberVariableContext = 0

    init(evaluator: ConstExprSourceEvaluator) {
        self.evaluator = evaluator
        super.init(viewMode: .sourceAccurate)
    }

    override func visitAny(_ node: Syntax) -> Syntax? {
        // Macro arguments may be inspected more than once or encoded into the
        // expansion result; rewriting them without expanding the macro is not
        // semantics-preserving.
        if node.is(MacroExpansionExprSyntax.self) {
            return node
        }
        // Closure bodies need the declaration-aware traversal below.
        if node.is(ClosureExprSyntax.self)
            || node.is(IfExprSyntax.self)
            || node.is(SwitchExprSyntax.self)
        {
            return nil
        }
        guard let expression = node.as(ExprSyntax.self) else { return nil }
        if containsDeferredSemantics(expression) {
            return nil
        }
        let result: ConstExprEvaluation
        if requireExplicitLiteralContext > 0,
           implicitReturnTypes[expression.id] == nil
        {
            result = evaluator.evaluateWithUnknownLiteralContext(
                expression,
                depth: 0,
                allowRegisteredCalls: suppressRegisteredCalls == 0
            )
        } else {
            result = evaluator.evaluate(
                expression,
                allowRegisteredCalls: suppressRegisteredCalls == 0,
                expectedTypeName: implicitReturnTypes[expression.id]
            )
        }
        return Syntax(result.syntax)
    }

    override func visit(_ node: SourceFileSyntax) -> SourceFileSyntax {
        final class ResultBuilderCollector: SyntaxVisitor {
            var functionNames: Set<String> = []
            var associatedTypeNames: Set<String> = []
            var extensionMembers: Set<ConstExprSourceExtensionMember> = []

            init() { super.init(viewMode: .sourceAccurate) }

            override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
                if node.signature.parameterClause.parameters.contains(where: {
                    !$0.attributes.isEmpty && $0.type.trimmedDescription.contains("->")
                }) {
                    functionNames.insert(node.name.text)
                }
                return .visitChildren
            }

            override func visit(_ node: AssociatedTypeDeclSyntax) -> SyntaxVisitorContinueKind {
                // Extensions of a protocol inherit its associated type names,
                // but SwiftSyntax does not resolve the extended nominal for
                // us. A file-wide conservative shadow prevents treating an
                // associated type named `Int`, for example, as Swift.Int.
                associatedTypeNames.insert(node.name.text)
                return .skipChildren
            }

            override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
                let ownerName = node.extendedType.trimmedDescription
                for item in node.memberBlock.members {
                    let declaration = item.decl
                    if let function = declaration.as(FunctionDeclSyntax.self) {
                        extensionMembers.insert(.init(
                            ownerName: ownerName,
                            memberName: function.name.text
                        ))
                    } else if declaration.is(InitializerDeclSyntax.self) {
                        extensionMembers.insert(.init(ownerName: ownerName, memberName: "init"))
                    } else if declaration.is(SubscriptDeclSyntax.self) {
                        extensionMembers.insert(.init(ownerName: ownerName, memberName: "subscript"))
                    } else if let variable = declaration.as(VariableDeclSyntax.self) {
                        for binding in variable.bindings {
                            if let identifier = binding.pattern.as(IdentifierPatternSyntax.self) {
                                extensionMembers.insert(.init(
                                    ownerName: ownerName,
                                    memberName: identifier.identifier.text
                                ))
                            }
                        }
                    } else if let nested = Self.declaredTypeName(declaration) {
                        extensionMembers.insert(.init(
                            ownerName: ownerName,
                            memberName: nested
                        ))
                    }
                }
                return .visitChildren
            }

            private static func declaredTypeName(_ declaration: DeclSyntax) -> String? {
                if let declaration = declaration.as(StructDeclSyntax.self) { return declaration.name.text }
                if let declaration = declaration.as(ClassDeclSyntax.self) { return declaration.name.text }
                if let declaration = declaration.as(EnumDeclSyntax.self) { return declaration.name.text }
                if let declaration = declaration.as(ActorDeclSyntax.self) { return declaration.name.text }
                if let declaration = declaration.as(ProtocolDeclSyntax.self) { return declaration.name.text }
                if let declaration = declaration.as(TypeAliasDeclSyntax.self) { return declaration.name.text }
                return nil
            }
        }
        let collector = ResultBuilderCollector()
        collector.walk(node)
        resultBuilderFunctionNames = collector.functionNames
        evaluator.fileDeclaredTypeNames.formUnion(collector.associatedTypeNames)
        evaluator.sourceExtensionMembers.formUnion(collector.extensionMembers)
        predeclare(in: node.statements)
        return super.visit(node)
    }

    override func visit(_ node: FunctionCallExprSyntax) -> ExprSyntax {
        if node.trailingClosure != nil,
           let reference = node.calledExpression.as(DeclReferenceExprSyntax.self),
           resultBuilderFunctionNames.contains(reference.baseName.text)
        {
            // A result builder supplies hidden expression contexts and may
            // transform or evaluate each body expression more than once.
            return ExprSyntax(node)
        }
        return super.visit(node)
    }

    override func visit(_ node: AttributeSyntax) -> AttributeSyntax {
        // Attribute arguments are consumed by the compiler or a macro and may
        // be inspected as syntax rather than evaluated as ordinary Swift.
        node
    }

    override func visit(_ node: EnumCaseDeclSyntax) -> DeclSyntax {
        // Raw-value expressions inherit the enum's raw type, and associated
        // value defaults inherit their parameter types. Until those contexts
        // are modeled explicitly, even rewriting a child literal operator can
        // change the program's static type.
        DeclSyntax(node)
    }

    override func visit(_ node: IfConfigDeclSyntax) -> DeclSyntax {
        // Without evaluating the active compilation conditions, choosing one
        // branch would make binding propagation configuration-dependent.
        for clause in node.clauses {
            switch clause.elements {
            case .statements(let statements): predeclare(in: statements)
            case .decls(let members): predeclare(in: members)
            default: break
            }
        }
        return DeclSyntax(node)
    }

    override func visit(_ node: CodeBlockSyntax) -> CodeBlockSyntax {
        evaluator.scopes.push()
        defer { evaluator.scopes.pop() }
        predeclare(in: node.statements)
        return super.visit(node)
    }

    override func visit(_ node: MemberBlockSyntax) -> MemberBlockSyntax {
        evaluator.scopes.push()
        defer { evaluator.scopes.pop() }
        predeclare(in: node.members)
        return super.visit(node)
    }

    override func visit(_ node: MemberBlockItemSyntax) -> MemberBlockItemSyntax {
        guard node.decl.is(VariableDeclSyntax.self) else { return super.visit(node) }
        suppressBindingPropagation += 1
        memberVariableContext += 1
        defer {
            memberVariableContext -= 1
            suppressBindingPropagation -= 1
        }
        return super.visit(node)
    }

    override func visit(_ node: ForStmtSyntax) -> StmtSyntax {
        // The sequence is contextually converted to the annotated/inferred
        // pattern element type. Keep the loop opaque until that conversion and
        // iteration semantics are modeled together.
        StmtSyntax(node)
    }

    override func visit(_ node: RepeatStmtSyntax) -> StmtSyntax {
        // Loop bodies are runtime control flow; executing linked callbacks
        // while merely rewriting their source would be observably incorrect.
        StmtSyntax(node)
    }

    override func visit(_ node: DoStmtSyntax) -> StmtSyntax {
        guard !node.catchClauses.isEmpty else { return super.visit(node) }
        // Replacing the final throwing operation beneath `try` can make this
        // catch unreachable and turn valid source into a compiler error under
        // `-warnings-as-errors`. Nonthrowing registrations remain eligible.
        evaluator.suppressThrowingRegistrations += 1
        defer { evaluator.suppressThrowingRegistrations -= 1 }
        return super.visit(node)
    }

    override func visit(_ node: CatchClauseSyntax) -> CatchClauseSyntax {
        evaluator.scopes.push()
        defer { evaluator.scopes.pop() }
        suppressRegisteredCalls += 1
        defer { suppressRegisteredCalls -= 1 }
        if node.catchItems.isEmpty {
            evaluator.scopes.declare("error")
        } else {
            for item in node.catchItems {
                if let pattern = item.pattern {
                    for name in boundNames(in: pattern) {
                        evaluator.scopes.declare(name)
                    }
                }
            }
        }
        return super.visit(node)
    }

    override func visit(_ node: IfExprSyntax) -> ExprSyntax {
        evaluator.scopes.push()
        defer { evaluator.scopes.pop() }
        suppressRegisteredCalls += 1
        defer { suppressRegisteredCalls -= 1 }
        declareBindings(in: node.conditions)
        return super.visit(node)
    }

    override func visit(_ node: WhileStmtSyntax) -> StmtSyntax {
        evaluator.scopes.push()
        defer { evaluator.scopes.pop() }
        suppressRegisteredCalls += 1
        defer { suppressRegisteredCalls -= 1 }
        declareBindings(in: node.conditions)
        return super.visit(node)
    }

    override func visit(_ node: GuardStmtSyntax) -> StmtSyntax {
        // Successful guard bindings are visible to all following statements in
        // the current lexical scope. Declaring before visiting the initializer
        // is deliberately conservative and prevents unsafe outer substitution.
        declareBindings(in: node.conditions)
        suppressRegisteredCalls += 1
        defer { suppressRegisteredCalls -= 1 }
        return super.visit(node)
    }

    override func visit(_ node: SwitchExprSyntax) -> ExprSyntax {
        suppressRegisteredCalls += 1
        defer { suppressRegisteredCalls -= 1 }
        return super.visit(node)
    }

    override func visit(_ node: SwitchCaseSyntax) -> SwitchCaseSyntax {
        evaluator.scopes.push()
        defer { evaluator.scopes.pop() }
        predeclare(in: node.statements)
        if case .case(let label) = node.label {
            for item in label.caseItems {
                for name in boundNames(in: item.pattern) {
                    evaluator.scopes.declare(name)
                }
            }
        }
        return super.visit(node)
    }

    override func visit(_ node: SwitchCaseItemSyntax) -> SwitchCaseItemSyntax {
        // Expression patterns inherit the switch subject's type. Keep the
        // entire item opaque until that subject-to-pattern context is modeled.
        node
    }

    override func visit(
        _ node: MatchingPatternConditionSyntax
    ) -> MatchingPatternConditionSyntax {
        // Both the pattern expression and initializer participate in one
        // contextual match. Partial substitution can change either side's
        // inferred type.
        node
    }

    override func visit(_ node: ClosureExprSyntax) -> ExprSyntax {
        rewriteClosure(node)
    }

    private func rewriteClosure(_ node: ClosureExprSyntax) -> ExprSyntax {
        evaluator.scopes.push()
        defer { evaluator.scopes.pop() }
        let explicitlyThrows = permitsPropagatingThrows(
            node.signature?.effectSpecifiers?.throwsClause
        )
        if !explicitlyThrows { evaluator.suppressThrowingRegistrations += 1 }
        defer {
            if !explicitlyThrows { evaluator.suppressThrowingRegistrations -= 1 }
        }
        let returnType = node.signature?.returnClause?.type.trimmedDescription
        if returnType == nil { requireExplicitLiteralContext += 1 }
        defer {
            if returnType == nil { requireExplicitLiteralContext -= 1 }
        }
        expectedReturnTypes.append(returnType)
        defer { expectedReturnTypes.removeLast() }
        let implicitID = registerImplicitReturn(in: node.statements, as: returnType)
        defer {
            if let implicitID { implicitReturnTypes.removeValue(forKey: implicitID) }
        }
        predeclare(in: node.statements)
        if let signature = node.signature,
            let parameterClause = signature.parameterClause
        {
            for parameter in parameterClause.parametersForConstExpr {
                evaluator.scopes.declare(parameter)
            }
        }
        if let captures = node.signature?.capture?.items {
            for capture in captures where capture.name.text != "_" {
                evaluator.scopes.declare(capture.name.text)
            }
        }
        return super.visit(node)
    }

    override func visit(_ node: FunctionDeclSyntax) -> DeclSyntax {
        guard node.attributes.isEmpty else { return DeclSyntax(node) }
        evaluator.scopes.push()
        defer { evaluator.scopes.pop() }
        let propagatesThrows = permitsPropagatingThrows(
            node.signature.effectSpecifiers?.throwsClause
        )
        if !propagatesThrows { evaluator.suppressThrowingRegistrations += 1 }
        defer {
            if !propagatesThrows { evaluator.suppressThrowingRegistrations -= 1 }
        }
        declare(genericParameters: node.genericParameterClause)
        let returnType = node.signature.returnClause?.type.trimmedDescription
        expectedReturnTypes.append(returnType)
        defer { expectedReturnTypes.removeLast() }
        let implicitID = node.body.flatMap {
            registerImplicitReturn(in: $0.statements, as: returnType)
        }
        defer {
            if let implicitID { implicitReturnTypes.removeValue(forKey: implicitID) }
        }
        declare(parameters: node.signature.parameterClause.parameters)
        return super.visit(node)
    }

    override func visit(_ node: InitializerDeclSyntax) -> DeclSyntax {
        guard node.attributes.isEmpty else { return DeclSyntax(node) }
        evaluator.scopes.push()
        defer { evaluator.scopes.pop() }
        let propagatesThrows = permitsPropagatingThrows(
            node.signature.effectSpecifiers?.throwsClause
        )
        if !propagatesThrows { evaluator.suppressThrowingRegistrations += 1 }
        defer {
            if !propagatesThrows { evaluator.suppressThrowingRegistrations -= 1 }
        }
        declare(genericParameters: node.genericParameterClause)
        expectedReturnTypes.append(nil)
        defer { expectedReturnTypes.removeLast() }
        declare(parameters: node.signature.parameterClause.parameters)
        return super.visit(node)
    }

    override func visit(_ node: SubscriptDeclSyntax) -> DeclSyntax {
        guard node.attributes.isEmpty else { return DeclSyntax(node) }
        evaluator.scopes.push()
        defer { evaluator.scopes.pop() }
        declare(genericParameters: node.genericParameterClause)
        let returnType = node.returnClause.type.trimmedDescription
        expectedReturnTypes.append(returnType)
        defer { expectedReturnTypes.removeLast() }
        let implicitID = node.accessorBlock?.accessors
            .as(CodeBlockItemListSyntax.self)
            .flatMap { registerImplicitReturn(in: $0, as: returnType) }
        defer {
            if let implicitID { implicitReturnTypes.removeValue(forKey: implicitID) }
        }
        declare(parameters: node.parameterClause.parameters)
        return super.visit(node)
    }

    override func visit(_ node: StructDeclSyntax) -> DeclSyntax {
        guard node.attributes.isEmpty else { return DeclSyntax(node) }
        return withGenericParameterScope(node.genericParameterClause) { super.visit(node) }
    }

    override func visit(_ node: ClassDeclSyntax) -> DeclSyntax {
        guard node.attributes.isEmpty else { return DeclSyntax(node) }
        return withGenericParameterScope(node.genericParameterClause) { super.visit(node) }
    }

    override func visit(_ node: EnumDeclSyntax) -> DeclSyntax {
        guard node.attributes.isEmpty else { return DeclSyntax(node) }
        return withGenericParameterScope(node.genericParameterClause) { super.visit(node) }
    }

    override func visit(_ node: ActorDeclSyntax) -> DeclSyntax {
        guard node.attributes.isEmpty else { return DeclSyntax(node) }
        return withGenericParameterScope(node.genericParameterClause) { super.visit(node) }
    }

    override func visit(_ node: ProtocolDeclSyntax) -> DeclSyntax {
        guard node.attributes.isEmpty else { return DeclSyntax(node) }
        // Protocol primary associated types use the generic-parameter-clause
        // syntax and shadow ordinary nominal names in member declarations.
        return withGenericParameterScope(node.primaryAssociatedTypeClause) { super.visit(node) }
    }

    override func visit(_ node: ExtensionDeclSyntax) -> DeclSyntax {
        guard node.attributes.isEmpty else { return DeclSyntax(node) }
        return super.visit(node)
    }

    override func visit(_ node: DeinitializerDeclSyntax) -> DeclSyntax {
        guard node.attributes.isEmpty else { return DeclSyntax(node) }
        evaluator.suppressThrowingRegistrations += 1
        defer { evaluator.suppressThrowingRegistrations -= 1 }
        return super.visit(node)
    }

    override func visit(_ node: AccessorDeclSyntax) -> DeclSyntax {
        guard node.attributes.isEmpty else { return DeclSyntax(node) }
        evaluator.scopes.push()
        defer { evaluator.scopes.pop() }
        let propagatesThrows = permitsPropagatingThrows(
            node.effectSpecifiers?.throwsClause
        )
        if !propagatesThrows { evaluator.suppressThrowingRegistrations += 1 }
        defer {
            if !propagatesThrows { evaluator.suppressThrowingRegistrations -= 1 }
        }
        if let name = node.parameters?.name.text, name != "_" {
            evaluator.scopes.declare(name)
        } else {
            switch node.accessorSpecifier.text {
            case "set", "willSet": evaluator.scopes.declare("newValue")
            case "didSet": evaluator.scopes.declare("oldValue")
            default: break
            }
        }
        let implicitID: SyntaxIdentifier?
        if node.accessorSpecifier.text == "get", let body = node.body {
            implicitID = registerImplicitReturn(
                in: body.statements,
                as: expectedReturnTypes.last.flatMap { $0 }
            )
        } else {
            implicitID = nil
        }
        defer {
            if let implicitID { implicitReturnTypes.removeValue(forKey: implicitID) }
        }
        return super.visit(node)
    }

    override func visit(_ node: ReturnStmtSyntax) -> StmtSyntax {
        guard let expression = node.expression else { return super.visit(node) }
        var rewritten = node
        if containsDeferredSemantics(expression) {
            rewritten.expression = rewrite(expression, detach: true).cast(ExprSyntax.self)
        } else if requireExplicitLiteralContext > 0,
                  expectedReturnTypes.last.flatMap({ $0 }) == nil
        {
            // An implicit closure result is contextually typed by its caller.
            // That context is unavailable for an unregistered outer call, so
            // an explicit `return` must be as conservative as a single-
            // expression closure body.
            rewritten.expression = evaluator.evaluateWithUnknownLiteralContext(
                expression,
                depth: 0,
                allowRegisteredCalls: suppressRegisteredCalls == 0
            ).syntax
        } else {
            rewritten.expression = evaluator.evaluate(
                expression,
                allowRegisteredCalls: suppressRegisteredCalls == 0,
                expectedTypeName: expectedReturnTypes.last.flatMap { $0 }
            ).syntax
        }
        return StmtSyntax(rewritten)
    }

    override func visit(_ node: YieldStmtSyntax) -> StmtSyntax {
        guard case .single(let expression) = node.yieldedExpressions else {
            return super.visit(node)
        }
        var rewritten = node
        rewritten.yieldedExpressions = .single(
            evaluator.evaluate(
                expression,
                allowRegisteredCalls: suppressRegisteredCalls == 0,
                expectedTypeName: expectedReturnTypes.last.flatMap { $0 }
            ).syntax
        )
        return StmtSyntax(rewritten)
    }

    override func visit(_ node: FunctionParameterSyntax) -> FunctionParameterSyntax {
        guard let defaultValue = node.defaultValue else { return node }
        // A default argument cannot propagate an error even when its enclosing
        // declaration is `throws`; only `try?` and `try!` handle one locally.
        evaluator.suppressThrowingRegistrations += 1
        defer { evaluator.suppressThrowingRegistrations -= 1 }
        var rewritten = node
        var rewrittenDefault = defaultValue
        if containsDeferredSemantics(defaultValue.value) {
            rewrittenDefault.value = rewrite(
                defaultValue.value,
                detach: true
            ).cast(ExprSyntax.self)
        } else {
            rewrittenDefault.value = evaluator.evaluate(
                defaultValue.value,
                allowRegisteredCalls: suppressRegisteredCalls == 0,
                expectedTypeName: node.type.trimmedDescription
            ).syntax
        }
        rewritten.defaultValue = rewrittenDefault
        return rewritten
    }

    private func permitsPropagatingThrows(_ clause: ThrowsClauseSyntax?) -> Bool {
        guard let clause else { return false }
        return clause.throwsSpecifier.tokenKind == .keyword(.throws)
            && clause.type == nil
    }

    private func declare(parameters: FunctionParameterListSyntax) {
        for parameter in parameters {
            let token = parameter.secondName ?? parameter.firstName
            if token.text != "_" {
                evaluator.scopes.declare(token.text)
            }
        }
    }

    private func registerImplicitReturn(
        in statements: CodeBlockItemListSyntax,
        as sourceType: String?
    ) -> SyntaxIdentifier? {
        guard let sourceType,
            statements.count == 1,
            let statement = statements.first,
            case .expr(let expression) = statement.item
        else { return nil }
        implicitReturnTypes[expression.id] = sourceType
        return expression.id
    }

    override func visit(_ node: VariableDeclSyntax) -> DeclSyntax {
        var rewritten = node
        var bindings: [PatternBindingSyntax] = []
        let isImmutable = node.bindingSpecifier.tokenKind == .keyword(.let)

        for binding in node.bindings {
            var rewrittenBinding = binding
            var evaluatedValue: ConstExprValue?
            if let initializer = binding.initializer {
                let suppressPropagatingThrow = memberVariableContext > 0
                if suppressPropagatingThrow {
                    evaluator.suppressThrowingRegistrations += 1
                }
                var rewrittenInitializer = initializer
                let annotation = binding.typeAnnotation?.type.trimmedDescription
                let isImplicitClosureWithOuterContext = annotation != nil
                    && initializer.value.is(ClosureExprSyntax.self)
                let isContextualStringInterpolation = annotation.map {
                    let name = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    return name != "String" && name != "Swift.String"
                } == true && initializer.value.as(StringLiteralExprSyntax.self).map {
                    $0.segments.contains { segment in
                        if case .expressionSegment = segment { return true }
                        return false
                    }
                } == true
                if !node.attributes.isEmpty
                    || isImplicitClosureWithOuterContext
                    || isContextualStringInterpolation
                {
                    // Property wrappers, an outer closure type, and custom
                    // interpolation overloads all add compiler-provided
                    // contexts unavailable from the initializer syntax alone.
                    rewrittenInitializer = initializer
                } else if containsDeferredSemantics(initializer.value) {
                    rewrittenInitializer.value = rewrite(
                        initializer.value,
                        detach: true
                    ).cast(ExprSyntax.self)
                } else {
                    let result = evaluator.evaluate(
                        initializer.value,
                        allowRegisteredCalls: suppressRegisteredCalls == 0,
                        expectedTypeName: binding.typeAnnotation?.type.trimmedDescription
                    )
                    rewrittenInitializer.value = result.syntax
                    evaluatedValue = result.value
                }
                rewrittenBinding.initializer = rewrittenInitializer
                if suppressPropagatingThrow {
                    evaluator.suppressThrowingRegistrations -= 1
                }
            }
            let annotation = binding.typeAnnotation?.type.trimmedDescription
            if let annotation, let currentValue = evaluatedValue {
                evaluatedValue = evaluator.staticallyConverted(
                    currentValue,
                    toSourceType: annotation
                )
            }
            if let annotation, let accessorBlock = binding.accessorBlock {
                expectedReturnTypes.append(annotation)
                let implicitID: SyntaxIdentifier?
                let hasShorthandGetter: Bool
                if case .getter(let statements) = accessorBlock.accessors {
                    hasShorthandGetter = true
                    implicitID = registerImplicitReturn(in: statements, as: annotation)
                } else {
                    hasShorthandGetter = false
                    implicitID = nil
                }
                if hasShorthandGetter {
                    evaluator.suppressThrowingRegistrations += 1
                }
                rewrittenBinding.accessorBlock = rewrite(
                    accessorBlock,
                    detach: true
                ).cast(AccessorBlockSyntax.self)
                if hasShorthandGetter {
                    evaluator.suppressThrowingRegistrations -= 1
                }
                if let implicitID { implicitReturnTypes.removeValue(forKey: implicitID) }
                expectedReturnTypes.removeLast()
            }
            let annotationIsConfirmed = annotation == nil || evaluatedValue.map {
                evaluator.value($0, matchesSourceType: annotation!)
            } == true
            if annotation != nil, !annotationIsConfirmed {
                // Rewriting even a child can select the wrong default literal
                // type under an alias or other unresolved source type.
                rewrittenBinding.initializer = binding.initializer
                evaluatedValue = nil
            }

            let names = boundNames(in: binding.pattern)
            if names.count == 1,
                let identifier = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text
            {
                if let annotation {
                    evaluator.scopes.setSourceType(annotation, for: identifier)
                }
                if suppressBindingPropagation == 0,
                    isImmutable,
                    annotationIsConfirmed,
                    let evaluatedValue
                {
                    evaluator.scopes.assignConstant(
                        evaluator.erasingLiteralProvenance(evaluatedValue),
                        to: identifier
                    )
                } else {
                    evaluator.scopes.declare(identifier)
                }
            } else {
                for name in names {
                    evaluator.scopes.declare(name)
                }
            }
            bindings.append(rewrittenBinding)
        }
        rewritten.bindings = PatternBindingListSyntax(bindings)
        return DeclSyntax(rewritten)
    }

    private func predeclare(in statements: CodeBlockItemListSyntax) {
        for statement in statements {
            guard case .decl(let declaration) = statement.item else { continue }
            if let variable = declaration.as(VariableDeclSyntax.self) {
                for binding in variable.bindings {
                    for name in boundNames(in: binding.pattern) {
                        evaluator.scopes.declare(name)
                    }
                }
            } else if let function = declaration.as(FunctionDeclSyntax.self) {
                evaluator.scopes.declare(function.name.text)
            } else if let nominal = declaredTypeName(declaration) {
                evaluator.scopes.declare(nominal)
            }
        }
    }

    private func predeclare(in members: MemberBlockItemListSyntax) {
        for member in members {
            if let variable = member.decl.as(VariableDeclSyntax.self) {
                for binding in variable.bindings {
                    for name in boundNames(in: binding.pattern) {
                        evaluator.scopes.declare(name)
                    }
                }
            } else if let function = member.decl.as(FunctionDeclSyntax.self) {
                evaluator.scopes.declare(function.name.text)
            } else if let nominal = declaredTypeName(member.decl) {
                evaluator.scopes.declare(nominal)
            }
        }
    }

    private func boundNames(in pattern: PatternSyntax) -> [String] {
        final class Collector: SyntaxVisitor {
            var names: [String] = []

            init() {
                super.init(viewMode: .sourceAccurate)
            }

            override func visit(_ node: IdentifierPatternSyntax) -> SyntaxVisitorContinueKind {
                if node.identifier.text != "_" {
                    names.append(node.identifier.text)
                }
                return .skipChildren
            }
        }

        let collector = Collector()
        collector.walk(pattern)
        return collector.names
    }

    private func declareBindings(in conditions: ConditionElementListSyntax) {
        for element in conditions {
            let pattern: PatternSyntax?
            switch element.condition {
            case .optionalBinding(let binding): pattern = binding.pattern
            case .matchingPattern(let matching): pattern = matching.pattern
            default: pattern = nil
            }
            if let pattern {
                for name in boundNames(in: pattern) {
                    evaluator.scopes.declare(name)
                }
            }
        }
    }

    private func containsDeferredSemantics(_ expression: ExprSyntax) -> Bool {
        final class Finder: SyntaxVisitor {
            var found = false

            init() {
                super.init(viewMode: .sourceAccurate)
            }

            override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
                found = true
                return .skipChildren
            }

            override func visit(_ node: IfExprSyntax) -> SyntaxVisitorContinueKind {
                found = true
                return .skipChildren
            }

            override func visit(_ node: SwitchExprSyntax) -> SyntaxVisitorContinueKind {
                found = true
                return .skipChildren
            }

            override func visit(_ node: MacroExpansionExprSyntax) -> SyntaxVisitorContinueKind {
                found = true
                return .skipChildren
            }
        }

        let finder = Finder()
        finder.walk(expression)
        return finder.found
    }

    private func declaredTypeName(_ declaration: DeclSyntax) -> String? {
        if let declaration = declaration.as(StructDeclSyntax.self) { return declaration.name.text }
        if let declaration = declaration.as(ClassDeclSyntax.self) { return declaration.name.text }
        if let declaration = declaration.as(EnumDeclSyntax.self) { return declaration.name.text }
        if let declaration = declaration.as(ActorDeclSyntax.self) { return declaration.name.text }
        if let declaration = declaration.as(ProtocolDeclSyntax.self) { return declaration.name.text }
        if let declaration = declaration.as(TypeAliasDeclSyntax.self) { return declaration.name.text }
        if let declaration = declaration.as(AssociatedTypeDeclSyntax.self) { return declaration.name.text }
        return nil
    }

    private func declare(genericParameters clause: GenericParameterClauseSyntax?) {
        guard let clause else { return }
        for parameter in clause.parameters where parameter.name.text != "_" {
            evaluator.scopes.declare(parameter.name.text)
        }
    }

    private func declare(genericParameters clause: PrimaryAssociatedTypeClauseSyntax?) {
        guard let clause else { return }
        for parameter in clause.primaryAssociatedTypes where parameter.name.text != "_" {
            evaluator.scopes.declare(parameter.name.text)
        }
    }

    private func withGenericParameterScope(
        _ clause: GenericParameterClauseSyntax?,
        _ body: () -> DeclSyntax
    ) -> DeclSyntax {
        evaluator.scopes.push()
        defer { evaluator.scopes.pop() }
        declare(genericParameters: clause)
        return body()
    }

    private func withGenericParameterScope(
        _ clause: PrimaryAssociatedTypeClauseSyntax?,
        _ body: () -> DeclSyntax
    ) -> DeclSyntax {
        evaluator.scopes.push()
        defer { evaluator.scopes.pop() }
        declare(genericParameters: clause)
        return body()
    }
}

private extension ClosureSignatureSyntax.ParameterClause {
    var parametersForConstExpr: [String] {
        switch self {
        case .simpleInput(let parameters):
            return parameters.map(\.name.text).filter { $0 != "_" }
        case .parameterClause(let clause):
            return clause.parameters.compactMap { parameter in
                let token = parameter.secondName ?? parameter.firstName
                return token.text == "_" ? nil : token.text
            }
        }
    }
}
