import Foundation
import SwiftOperators
import SwiftParser
import SwiftParserDiagnostics
import SwiftSyntax

enum ConstExprRegisteredOperatorPreparationEvent: Hashable, Sendable {
    case sourceOperatorCollection
    case precedenceTableSerializationAndParse
    case syntheticDeclarationParse
}

/// An internal, task-scoped probe for keeping the registered-operator fast path
/// covered without introducing process-global test state.
enum ConstExprRegisteredOperatorPreparationProbe {
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [ConstExprRegisteredOperatorPreparationEvent] = []

        func record(_ event: ConstExprRegisteredOperatorPreparationEvent) {
            lock.withLock { storage.append(event) }
        }

        var events: [ConstExprRegisteredOperatorPreparationEvent] {
            lock.withLock { storage }
        }
    }

    @TaskLocal static var recorder: Recorder?

    static func record(_ event: ConstExprRegisteredOperatorPreparationEvent) {
        recorder?.record(event)
    }
}

extension ConstExprRunner {
    func installRegisteredOperatorDeclarations(
        in operatorTable: inout OperatorTable,
        sourceFile: SourceFileSyntax,
        fileName: String
    ) -> [ConstExprDiagnostic] {
        let registrations = registry.index.usableRegistrations
        let registeredOperators = registrations.compactMap(RegisteredOperator.init)
        guard !registeredOperators.isEmpty else { return [] }
        let grouped = Dictionary(grouping: registeredOperators) {
            $0.key
        }
        let keysRequiringSynthesis = grouped.keys.filter {
            !$0.isInstalled(in: operatorTable)
        }
        // The standard table and declarations already loaded from this source
        // are authoritative. Most registries only add overload implementations
        // for these operators, so avoid rendering and reparsing the table.
        guard !keysRequiringSynthesis.isEmpty else { return [] }

        ConstExprRegisteredOperatorPreparationProbe.record(.sourceOperatorCollection)
        let declaredOperators = SourceOperatorCollector.collect(from: sourceFile)
        let undeclaredKeys = keysRequiringSynthesis.filter {
            !declaredOperators.contains($0)
        }
        guard !undeclaredKeys.isEmpty else { return [] }

        ConstExprRegisteredOperatorPreparationProbe.record(
            .precedenceTableSerializationAndParse
        )
        let precedenceAssociativities = PrecedenceGroupAssociativityCollector.collect(
            from: operatorTable.description
        )
        var diagnostics: [ConstExprDiagnostic] = []

        for key in undeclaredKeys.sorted() {
            guard let operators = grouped[key] else { continue }
            // A real source declaration or the standard table is the
            // authoritative grouping contract. Registration metadata is used
            // only to synthesize a declaration for an otherwise unknown key.
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
            ConstExprRegisteredOperatorPreparationProbe.record(.syntheticDeclarationParse)
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
