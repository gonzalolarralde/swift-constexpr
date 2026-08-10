import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

enum ConstExprMacroDiagnostic {
    static func error(
        _ message: String,
        id: String,
        at node: some SyntaxProtocol,
        in context: some MacroExpansionContext
    ) {
        context.diagnose(
            Diagnostic(
                node: Syntax(node),
                message: Message(message: message, id: id, severity: .error)
            )
        )
    }

    static func warning(
        _ message: String,
        id: String,
        at node: some SyntaxProtocol,
        in context: some MacroExpansionContext
    ) {
        context.diagnose(
            Diagnostic(
                node: Syntax(node),
                message: Message(message: message, id: id, severity: .warning)
            )
        )
    }

    private struct Message: DiagnosticMessage {
        let message: String
        let diagnosticID: MessageID
        let severity: DiagnosticSeverity

        init(message: String, id: String, severity: DiagnosticSeverity) {
            self.message = message
            self.diagnosticID = MessageID(domain: "ConstExprMacros", id: id)
            self.severity = severity
        }
    }
}
