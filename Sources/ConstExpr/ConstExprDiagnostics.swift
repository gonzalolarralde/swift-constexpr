/// A stable source location independent of SwiftSyntax's in-memory tree.
public struct ConstExprSourceLocation: Sendable, Equatable, Hashable {
    public var fileName: String
    public var line: Int
    public var column: Int
    /// A zero-based UTF-8 byte offset into the original source, when known.
    public var offset: Int?

    public init(
        fileName: String = "<memory>",
        line: Int = 1,
        column: Int = 1,
        offset: Int? = nil
    ) {
        self.fileName = fileName
        self.line = line
        self.column = column
        self.offset = offset
    }
}

/// A diagnostic produced while parsing, resolving, or evaluating a source
/// expression. Ordinary unregistered source is intentionally not diagnostic.
public struct ConstExprDiagnostic: Sendable, Equatable, CustomStringConvertible {
    public enum Severity: String, Sendable, Equatable {
        case note
        case warning
        case error
    }

    public let severity: Severity
    public let code: String
    public let message: String
    public let fileName: String
    public let line: Int
    public let column: Int
    /// A zero-based UTF-8 byte offset into the original source, when known.
    public let offset: Int?

    public init(
        severity: Severity,
        code: String,
        message: String,
        fileName: String = "<memory>",
        line: Int = 1,
        column: Int = 1,
        offset: Int? = nil
    ) {
        self.severity = severity
        self.code = code
        self.message = message
        self.fileName = fileName
        self.line = line
        self.column = column
        self.offset = offset
    }

    public init(
        severity: Severity,
        code: String,
        message: String,
        location: ConstExprSourceLocation
    ) {
        self.init(
            severity: severity,
            code: code,
            message: message,
            fileName: location.fileName,
            line: location.line,
            column: location.column,
            offset: location.offset
        )
    }

    public var location: ConstExprSourceLocation {
        ConstExprSourceLocation(
            fileName: fileName,
            line: line,
            column: column,
            offset: offset
        )
    }

    public var isError: Bool {
        severity == .error
    }

    public var description: String {
        "\(fileName):\(line):\(column): \(severity.rawValue) [\(code)]: \(message)"
    }
}

public typealias ConstExprDiagnosticSeverity = ConstExprDiagnostic.Severity

/// Resource and behavior limits for a single source rewrite.
public struct ConstExprRewriteOptions: Sendable, Equatable {
    /// Maximum expression nodes visited during one rewrite. Values below one
    /// are normalized to one when evaluation begins.
    public var maximumEvaluationSteps: Int
    /// Maximum recursive expression depth during one rewrite. Values below one
    /// are normalized to one when evaluation begins.
    public var maximumRecursionDepth: Int

    public init(
        maximumEvaluationSteps: Int = 10_000,
        maximumRecursionDepth: Int = 256
    ) {
        self.maximumEvaluationSteps = maximumEvaluationSteps
        self.maximumRecursionDepth = maximumRecursionDepth
    }

    public static let `default` = Self()
}

/// The rewritten source and all recoverable diagnostics produced while
/// processing it.
public struct ConstExprRewriteResult: Sendable, Equatable {
    public let source: String
    public let diagnostics: [ConstExprDiagnostic]

    public init(source: String, diagnostics: [ConstExprDiagnostic] = []) {
        self.source = source
        self.diagnostics = diagnostics
    }

    public var hasDiagnostics: Bool {
        !diagnostics.isEmpty
    }

    public var hasErrors: Bool {
        diagnostics.contains(where: \.isError)
    }
}
