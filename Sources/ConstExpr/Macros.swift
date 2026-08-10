/// Generates a runtime registration peer for a declaration that is safe to
/// evaluate while rewriting source.
///
/// The generated peer does not execute during macro expansion. It is linked
/// into a runner and invokes the annotated declaration when a source expression
/// can be resolved entirely from constant inputs.
@attached(peer, names: suffixed(__constExpr))
public macro ConstExpr() =
    #externalMacro(module: "ConstExprMacros", type: "ConstExprMacro")

/// Builds a registry from declarations annotated with ``ConstExpr``.
///
/// Function overloads can be selected with an explicit cast, for example:
///
/// ```swift
/// #constExprRegistry(parse(_:) as (Int) -> String)
/// ```
@freestanding(expression)
public macro constExprRegistry(_ declarations: Any...) -> ConstExprRegistry =
    #externalMacro(module: "ConstExprMacros", type: "ConstExprRegistryMacro")
