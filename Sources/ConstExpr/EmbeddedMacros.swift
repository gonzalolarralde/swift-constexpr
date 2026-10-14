#if hasFeature(Embedded)
/// Source-compatible annotation in Embedded builds. It generates no peers;
/// the host copy of the same model retains normal registration behavior.
@attached(
    peer,
    names: suffixed(__constExpr), named(init__constExpr), named(subscript__constExpr)
)
public macro ConstExpr(
    registrationAccess: ConstExprRegistrationAccess = .declaration
) =
    #externalMacro(module: "ConstExprMacros", type: "ConstExprNoOpPeerMacro")

/// Source-compatible extension annotation; emits no members in Embedded builds.
@attached(member, names: arbitrary)
public macro ConstExprMembers(
    registrationAccess: ConstExprRegistrationAccess = .declaration
) =
    #externalMacro(module: "ConstExprMacros", type: "ConstExprNoOpMemberMacro")

/// Source-compatible named extension annotation; emits no Embedded members.
@attached(member, names: arbitrary)
public macro ConstExprMembers(
    named: String,
    registrationAccess: ConstExprRegistrationAccess = .declaration
) =
    #externalMacro(module: "ConstExprMacros", type: "ConstExprNoOpMemberMacro")

/// Preserves the host annotation's exclusion marker without generating code.
@attached(peer, names: arbitrary)
public macro ConstExprIgnored() =
    #externalMacro(module: "ConstExprMacros", type: "ConstExprIgnoredMacro")

#endif
