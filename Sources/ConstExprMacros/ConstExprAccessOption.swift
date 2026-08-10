import SwiftSyntax
import SwiftSyntaxMacros

enum ConstExprRegistrationAccessOption {
    case declaration
    case package

    init(
        attribute: AttributeSyntax,
        in context: some MacroExpansionContext
    ) {
        guard case .argumentList(let arguments) = attribute.arguments,
              let argument = arguments.first(where: {
                  $0.label?.constExprIdentifier == "registrationAccess"
              })
        else {
            self = .declaration
            return
        }

        let spelling = argument.expression.constExprSource
            .replacingOccurrences(of: " ", with: "")
        switch spelling {
        case ".package", "ConstExprRegistrationAccess.package":
            self = .package
        case ".declaration", "ConstExprRegistrationAccess.declaration":
            self = .declaration
        default:
            ConstExprMacroDiagnostic.error(
                "registrationAccess must be .declaration or .package",
                id: "invalid-registration-access",
                at: argument.expression,
                in: context
            )
            self = .declaration
        }
    }

    func accessPrefix(
        declarationModifiers: DeclModifierListSyntax,
        enclosingAccess: ConstExprAccessLevel? = nil,
        inheritedDeclarationAccess: ConstExprAccessLevel? = nil
    ) -> String {
        let declarationAccess = declarationModifiers.constExprExplicitAccessLevel
            ?? inheritedDeclarationAccess
            ?? .internal
        let effectiveAccess = enclosingAccess.map { min($0, declarationAccess) }
            ?? declarationAccess
        let peerAccess: ConstExprAccessLevel
        switch self {
        case .declaration:
            peerAccess = effectiveAccess
        case .package:
            peerAccess = min(.package, effectiveAccess)
        }
        return peerAccess.sourcePrefix
    }

    var registrationArrayType: String {
        switch self {
        case .declaration:
            return "[_ConstExprRuntime.Registration]"
        case .package:
            // Erasing the package peer's return type keeps an internal import
            // of ConstExpr out of the annotated module's package/public API.
            return "[Any]"
        }
    }

    func erasedRegistrationPrefix(_ source: String) -> String {
        switch self {
        case .declaration:
            return source
        case .package:
            return "(\(source)).map { $0 as Any }"
        }
    }

    func accessLevel(
        declarationModifiers: DeclModifierListSyntax,
        enclosingAccess: ConstExprAccessLevel? = nil
    ) -> ConstExprAccessLevel {
        let declarationAccess = declarationModifiers.constExprAccessLevel
        let effectiveAccess = enclosingAccess.map { min($0, declarationAccess) }
            ?? declarationAccess
        switch self {
        case .declaration:
            return effectiveAccess
        case .package:
            return min(.package, effectiveAccess)
        }
    }
}

extension ConstExprAccessLevel {
    var sourcePrefix: String {
        switch self {
        case .private:
            return "private "
        case .fileprivate:
            return "fileprivate "
        case .internal:
            return ""
        case .package:
            return "package "
        case .public:
            return "public "
        }
    }
}
