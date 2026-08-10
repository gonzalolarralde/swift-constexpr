import SwiftSyntax

struct ConstExprPreparedSource {
    let foldedSyntax: SourceFileSyntax?
    let diagnostics: [ConstExprDiagnostic]
    let hasByteOrderMark: Bool
}
