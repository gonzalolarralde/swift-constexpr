/// Reserved namespace used by macro-generated source.
///
/// Keeping generated references behind one deliberately uncommon name avoids
/// collisions when a client declares its own `ConstExprValue`,
/// `ConstExprRegistration`, `ConstExprRegistry`, or `ConstExprValueError`.
public enum _ConstExprRuntime {
    public typealias Value = ConstExprValue
    public typealias Registration = ConstExprRegistration
    public typealias Registry = ConstExprRegistry
    public typealias StaticTypeDescriptor = ConstExprStaticTypeDescriptor
    public typealias ValueError = ConstExprValueError
    public typealias RegistrationProviding = ConstExprRegistrationProviding

    /// Lets macro-generated code ask Swift's overload resolver whether a
    /// declaration result is statically convertible to `AnyObject`. The
    /// non-generic overload wins for classes, `AnyObject`, and class-bound
    /// protocol existentials; the generic fallback covers value types, `Any`,
    /// and non-class-bound existentials.
    public static func isStaticallyAnyObject<T>(_: T?) -> Bool { false }
    public static func isStaticallyAnyObject(_: AnyObject?) -> Bool { true }

    /// Shadow-safe macro hook. A syntactic conformance spelling may name a
    /// client-defined protocol instead of Swift's `ExpressibleByArrayLiteral`;
    /// in that case (or when the inferred element type is not the associated
    /// type) this unconstrained overload deliberately contributes nothing.
    public static func arrayLiteralRegistrations<Result, Element>(
        result: Result.Type,
        element: Element.Type,
        elementTypeDescriptor: StaticTypeDescriptor,
        resultTypeDescriptor: StaticTypeDescriptor? = nil,
        moduleName: String?
    ) -> [Registration] {
        []
    }

    /// Adds the bounded protocol-witness adapter generated for an annotated
    /// primary declaration whose conformance and witness shape were visible to
    /// the macro.
    public static func arrayLiteralRegistrations<Result, Element>(
        result: Result.Type,
        element: Element.Type,
        elementTypeDescriptor: StaticTypeDescriptor,
        resultTypeDescriptor: StaticTypeDescriptor? = nil,
        moduleName: String?
    ) -> [Registration]
    where Result: ExpressibleByArrayLiteral & SendableMetatype,
          Element: SendableMetatype,
          Result.ArrayLiteralElement == Element {
        [
            .arrayLiteral(
                moduleName: moduleName,
                result: result,
                element: element,
                elementTypeDescriptor: elementTypeDescriptor,
                resultTypeDescriptor: resultTypeDescriptor
            )
        ]
    }
}

/// A generated, statically discoverable fragment of a constant-expression
/// registry.
///
/// The associated owner lets ``constExprRegistry(for:extensions:)`` reject an
/// extension fragment from a different nominal type at compile time. The
/// payload is deliberately erased so package-scoped generated providers can
/// remain absent from a library's public interface.
public protocol ConstExprRegistrationProviding {
    associatedtype Owner

    static var constExprRegistrations: [Any] { get }
}

public extension _ConstExprRuntime {
    /// Recovers a typed registration fragment while proving its generated
    /// provider belongs to the requested root type.
    static func registrations<Owner, Provider>(
        for _: Owner.Type,
        from _: Provider.Type
    ) -> [Registration]
    where Provider: ConstExprRegistrationProviding, Provider.Owner == Owner {
        registrations(fromGeneratedPeer: Provider.constExprRegistrations)
    }
}
