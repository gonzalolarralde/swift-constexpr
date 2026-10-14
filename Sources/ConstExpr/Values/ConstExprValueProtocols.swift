#if !hasFeature(Embedded)
public enum ConstExprValueError: Error, Sendable, Equatable, CustomStringConvertible {
    case typeMismatch(expected: String, actual: String)
    case notRepresentable(String)
    case malformedCollection(String)

    public var description: String {
        switch self {
        case .typeMismatch(let expected, let actual):
            "expected \(expected), found \(actual)"
        case .notRepresentable(let type):
            "\(type) cannot be rendered as a Swift constant expression"
        case .malformedCollection(let message):
            message
        }
    }
}
/// Describes source-literal provenance used during overload resolution.
///
/// Swift permits an integer literal to initialize several numeric types and a
/// one-character string literal to initialize `Character`. Those conversions
/// must not be applied to an arbitrary computed `Int` or `String`, so ordinary
/// ``ConstExprValue/init(_:)`` values intentionally have no literal provenance.
public enum ConstExprLiteralKind: String, Sendable, Hashable {
    case integer
    case floatingPoint
    case string
    case boolean
    case nilLiteral
}

/// The structural category of a constant-expression value.
public enum ConstExprValueKind: String, Sendable, Hashable {
    case opaque
    case optional
    case array
    case dictionary
    case tuple
}

/// A type that can be decoded from the evaluator's structural value model.
public protocol ConstExprValueDecodable {
    static func decodeConstExprValue(_ value: ConstExprValue) throws -> Self
}

// These private protocols describe standard-library container metatypes, not
// their instances. The metatypes are safe to share even for non-Sendable
// elements. Making that explicit also avoids a Swift 6.4 snapshot region-
// analysis assertion when an existential metadata getter returns Any.Type.
protocol ConstExprOptionalTypeMetadata: SendableMetatype {
    static var constExprWrappedType: Any.Type { get }
    static func constExprNilValue() -> ConstExprValue
    static func constExprWrappedValue(from value: Any) -> ConstExprValue?
}

protocol ConstExprArrayTypeMetadata: SendableMetatype {
    static var constExprElementType: Any.Type { get }
    static func constExprElements(from value: Any) -> [ConstExprValue]?
}

protocol ConstExprSetTypeMetadata: SendableMetatype {
    static var constExprElementType: Any.Type { get }
}

protocol ConstExprDictionaryTypeMetadata: SendableMetatype {
    static var constExprKeyType: Any.Type { get }
    static var constExprValueType: Any.Type { get }
    static func constExprEntries(
        from value: Any
    ) -> [(ConstExprValue, ConstExprValue)]?
}

/// Standard-library containers whose array-literal construction can be opened
/// safely for an erased exact metatype. This is intentionally private: user
/// conformances require an explicit registry adapter before their code runs.
protocol ConstExprStandardArrayLiteralTypeMetadata: SendableMetatype {
    static var constExprArrayLiteralElementType: Any.Type { get }
    static func constExprArrayLiteralValue(
        from elements: [ConstExprValue],
        sourceTypeName: String
    ) throws -> ConstExprValue
}

/// Opens a standard-library container's generic arguments so structural
/// values can be decoded even when their custom element types do not conform
/// to `ConstExprValueDecodable`. Exact opaque elements already know how to
/// decode themselves through `require`, so imposing a conformance on every
/// annotated nominal would be unnecessary boilerplate.
protocol ConstExprStructuralValueDecodable {
    static func decodeStructuralConstExprValue(_ value: ConstExprValue) throws -> Any
}

/// Retains a structural value's complete source-static expression while its
/// outer type is erased to a leaf such as `Any`. Rendering the wrapped value
/// first is essential for optionals and heterogeneous containers: erasing each
/// child independently would change the runtime value being boxed.
package struct ConstExprStructurallyErasedValue {
    package let value: ConstExprValue

    package init(value: ConstExprValue) { self.value = value }
}
#endif
