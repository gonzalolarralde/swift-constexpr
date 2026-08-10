# ConstExpr architecture

ConstExpr is a linked source rewriter, not an interpreter and not a compiler
optimization pass. The process that performs a rewrite imports both the
`ConstExpr` runtime and the library containing the declarations it is allowed to
execute. Macro-generated adapters call those already-compiled declarations. The
package requires Swift 6.3 or newer and currently deploys to macOS 11 or newer.

## Components

The package has four layers:

1. `@ConstExpr` emits type-safe registration peers. A free function or global
   `let` gets a suffixed factory function. A nominal type gets a sibling provider
   containing registrations for sufficiently visible explicit initializers,
   nonmutating/nonconsuming methods, explicitly typed properties with ordinary
   getters, enum cases, and read-only instance subscripts in its primary body.
2. `#constExprRegistry(...)` turns explicit declaration references into one
   immutable `ConstExprRegistry` value. Function casts select overloads.
3. `ConstExprRunner` parses a complete source file, folds Swift operator
   sequences with `SwiftOperators`, tracks lexical constants, and evaluates
   syntax bottom-up.
4. `ConstExprValue` carries either a renderable scalar/collection or an opaque
   runtime value. An opaque value can be the receiver of another registered
   operation even though it cannot itself be emitted as source.

Swift attached macros cannot enumerate all annotated declarations in a module.
That is why registry aggregation is explicit. A future build-tool plugin could
generate the aggregation call, but hidden global self-registration would be
order-dependent and Swift globals are lazily initialized.

Generated peers refer to runtime support through the public
`_ConstExprRuntime` namespace, avoiding collisions with ordinary support-type
names. That namespace name is reserved in client scopes where `@ConstExpr` or
`#constExprRegistry` expands.

## Evaluation algorithm

Expressions are evaluated bottom-up within declaration-aware syntax traversal.
Evaluation produces two independent results:

- rewritten syntax, which may contain constant children even when the parent is
  unknown;
- an optional typed runtime value, which may remain opaque for a later member in
  a registered chain.

This distinction enables both important cases:

```swift
external(foo(1))       // external(2)
Foo().bar.blah()       // "5"
```

A registered operation runs only after its receiver and every supplied argument
are known. `&&`, `||`, `??`, and the ternary operator preserve laziness and do not
execute an unselected registered branch. Annotated code must not depend on
evaluation order or other side effects. A throwing adapter executes only beneath
a source-level `try`, `try?`, or `try!`. An unmarked throwing call remains source;
if an allowed invocation throws, it also remains source and reports a diagnostic.
Throwing authorization does not cross a nested closure boundary. A plain `try`
also remains when it determines an inferred closure effect, appears in a
catch-bearing `do` body, or occurs outside an ordinary untyped `throws` boundary.
`rethrows` and typed-throws boundaries remain conservative because the evaluator
cannot prove their source restrictions. This prevents a fold from making a `catch` unreachable or repairing invalid
source. `try?` and `try!` handle the error locally and can still fold. A redundant
`try`, `try?`, or `try!` around a nonthrowing fold remains in source so its compiler
diagnostic is not erased.

Structured control flow is a conservative boundary. Registered calls are not
executed while traversing `if`/`switch` bodies, loops, guard conditions, catch
clauses, or conditional-compilation branches. Context-independent child syntax
may still simplify. Macro and attribute arguments remain opaque syntax. A
declaration carrying attributes—including a function, initializer, subscript,
nominal type, protocol, extension, deinitializer, or accessor—is retained
wholesale; an attributed variable's initializer is also retained because an
attached macro may inspect its original syntax. Unattributed accessors may use
their declared result type as folding context. A call with a trailing closure is
not itself eligible for registry matching. An implicit closure result has unknown
caller-provided type context, so only context-independent descendants are
simplified. Calls identified syntactically
as result-builder entry points remain wholly opaque because builder transforms add
hidden expression contexts.

Replacement expressions copy the outer trivia of the original expression.
Expressions containing internal comments are retained conservatively so a fold
cannot erase or relocate a comment. Running the rewriter repeatedly is intended
to be idempotent. A leading UTF-8 byte-order mark and existing CRLF trivia are
preserved.

## Values and static types

Built-in renderers cover booleans, strings, characters, all fixed-width integer
types, `Float`, `Double`, optionals, arrays, sets, and dictionaries. Bare Swift
literals are emitted only when they preserve the original static type. Other
values include an explicit cast, for example:

```swift
(5) as Swift.Int64
(1.5) as Swift.Float
("x") as Swift.Character
nil as Int?
```

This rule matters because changing `Int64` to an unannotated integer literal can
change overload resolution in the rewritten program. Literal provenance is also
retained during evaluation: source literal `1` can be decoded for an `Int64`
parameter, but a computed result whose static type is `Int` is not silently
widened to `Int64`.

Recognized type context comes from explicit bindings, returns, parameter defaults,
casts, simple assignments, typed sibling operands/elements, registered direct,
instance, or static call arguments, nil coalescing, and structural annotations. A
type alias or context available only through an unresolved outer expression is not
guessed; the affected source is preserved.

Custom terminal types can conform to `ConstExprRepresentable`. Custom parameter
types can conform to `ConstExprValueDecodable`. Most annotated nominal values do
not need either conformance when they are only intermediate receivers. A custom
renderer must return exactly one complete Swift expression with the declared
static type and value. Its text is reparsed in one synthetic binding; parser
recovery, extra bindings, or extra statements reject the replacement.

Structural tuple literals can be decoded as direct registration arguments at
arities two through four. A tuple of another arity can still flow from one
registration to another when the first produces an exact boxed runtime tuple; an
unboxed source tuple literal of that shape remains unsupported.

## Resolution

Registrations describe the declaration kind, owner type, external labels,
parameter types, recursively structured static-type descriptors, defaulted
positions, result type, throwing effect, operator metadata, array-literal
element type and optional arity bound, and a stable declaration ID.
Macro-generated descriptors retain tuple/container element and
existential information that cannot be recovered reliably from an erased
`Any.Type`; a manual registration can provide the same descriptors explicitly.
Descriptors recursively preserve optional, array, dictionary, tuple, existential,
and class-bound structure. Registry validation checks that this structure matches
the top-level metatypes, but manual source spellings, class-bound flags, and
source-type predicates are trusted semantic claims. The macro-generated predicates
are compiler-checked. A manual registration's `isThrowing` flag is trusted too.

Resolution first filters by syntactic role, name, labels, and arity. It then checks
value conversions without invoking user code. Exact types rank ahead of
literal-directed conversions, and an otherwise-equivalent exact-arity overload
ranks ahead of one requiring defaults. If there is no unique best candidate,
source is retained and an ambiguity diagnostic is returned.

Leading-dot syntax is resolved only from an available expected type. For
`.init(...)`, the evaluator considers initializer registrations owned by that
contextual nominal. For `.factory(...)` and `.value`, it considers static method
or property registrations on that same owner. Result-type coincidence is not
enough: a `B.make() -> A` registration cannot satisfy `let value: A = .make()`
because Swift looks for `A.make`. Argument labels and values still pass through
ordinary overload ranking, and a missing context or tied result remains source.

Scalar custom literal conversion is likewise registration-driven. The linked
target metatype must actually conform to the corresponding
`ExpressibleByStringLiteral`, `ExpressibleByIntegerLiteral`,
`ExpressibleByFloatLiteral`, or `ExpressibleByBooleanLiteral` protocol. The
evaluator opens that conformance to recover its associated literal type, then
requires one nonthrowing registered initializer with the protocol label and exact
associated parameter type. It never calls an unregistered protocol witness.
Array literals recursively receive context from either a standard container or
one exact `.arrayLiteral` registration. `Array` and `Set` provide unlimited
standard adapters through this common path. For a user-owned annotated nominal,
the macro emits an adapter only when the primary declaration directly names
`ExpressibleByArrayLiteral` (including the `Swift.`-qualified spelling) and
contains exactly one visible, eligible `init(arrayLiteral:)` witness. A
compiler-constrained overload probe verifies the real standard-library
conformance and associated element type, so a shadowing protocol with the same
name contributes no registration.

Stable Swift cannot convert `(Element...) -> Result` into
`([Element]) -> Result`. The shared generated-witness trampoline therefore spells
arities zero through 32 explicitly. A literal above that bound is retained with
a diagnostic. `ConstExprRegistration.arrayLiteral(..., build:)` lets a library
author provide an array-backed, unbounded adapter when the type has such a
construction path. More than one exact adapter, an unknown element, or missing
expected context remains source rather than selecting or partially invoking a
witness.

Default metadata is recorded because a Swift function value does not carry default
arguments. A free-function peer evaluates its copied defaults in the same source
file. Nominal-member adapters instead select an invocation branch that leaves
absent arguments out of the call to the original declaration, so Swift evaluates
each default in the declaration's lexical context. Caller-location defaults such
as `#file` and `#line` are rejected because the rewriting process would be a
different call site.

Module-qualified functions/constants and qualified static members are supported.
The qualification root must not be shadowed by a lexical declaration, and a
qualified owner is matched by its exact or qualified-suffix name rather than by an
unrelated basename.

This is intentionally not a replacement for the Swift constraint solver.
Generic declarations, implicit conversions requiring semantic type checking,
and unresolved return-type-only overloads remain source unless an available
explicit context selects one safely.

Declarations visible in the input are conservative shadows. A source function
blocks an unqualified registration with the same name. A member declared in a
source extension blocks every registration with the same matching owner spelling
and member name, even if its written signature differs; an unqualified extension
owner matches by basename. Conversely, an imported overload omitted from the
registry is invisible to the runner and can therefore invalidate its choice.
Registries for overloaded imported APIs and operators must include every competitor
that could be selected at the intended call sites.

## Lexical constants

The runner records simple immutable `let` bindings after evaluating their
initializer. Nested code blocks push a new frame and restore the outer frame on
exit. Function and closure parameters, loop/catch/case patterns, local
declarations, mutable variables, and unsupported patterns introduce conservative
unknown shadows so an outer constant is never substituted for a different Swift
declaration.

`var` initializers may contain independently foldable expressions, but mutable
bindings never propagate. The implementation does not perform control-flow or
assignment analysis. This keeps rewriting safe around branches, loops, captures,
and mutation.

## Operators

The standard Swift precedence table is applied before evaluation. Primitive
operators include checked integer arithmetic, wrapping arithmetic, bitwise and
shift operations, numeric and string comparisons, string concatenation, and
Boolean logic. Division by zero and checked overflow are diagnosed and left
unchanged; shifts follow Swift's behavior for negative and oversized counts.

Additional prefix, infix, and postfix operations can be installed manually with
`ConstExprRegistration` helpers. When the input does not repeat an imported
operator declaration, the runner now installs a temporary declaration in the
`SwiftOperators` table from the registration's fixity and precedence-group
metadata. That declaration is used only to fold the parsed tree and is never
emitted into rewritten source. A declaration already present in the input (or in
the standard table) remains authoritative. When synthesis is required, non-nil
precedence and associativity claims across overload registrations for one fixity
and symbol must not conflict; conflicts are diagnosed and the operator is not executed.
An infix precedence-group name must refer to a standard group or a group declared
in the input, because the registry does not attempt to recreate an imported
group's `higherThan`/`lowerThan` relationships. Associativity belongs to the
precedence group, not to one operator declaration. For a synthesized operator,
registration associativity is validation metadata checked against that group's
authoritative value; a mismatch is diagnosed instead of regrouping the expression.
An operator declaration present in the input or an entry in the standard table is
authoritative, and its registration metadata is ignored.
Throwing operator factories must set `isThrowing: true`, which makes the same
source-level `try` gate apply as for other throwing registrations.

## Trust boundary

Every adapter executes in-process. Annotation is a promise that the declaration
is deterministic, terminating, nonmutating, and safe during a build. The runtime
cannot prevent an annotated function from trapping, hanging, reading files,
using the network, or changing global state. Node and recursion limits bound the
expression evaluator's work; they cannot interrupt arbitrary linked user code.

The first implementation excludes async, `rethrows`, and typed `throws(E)` APIs;
generics; `Void`, `Never`, opaque, and function-valued results; ordinary
variadics; `inout`,
ownership-qualified, autoclosure, and closure-valued parameters; mutating or
consuming methods; lazy properties and mutating, consuming, or effectful getters;
static, writable, or effectful subscripts; member-scoped availability or SPI;
dynamic members; overridable instance methods, properties, and subscripts on a
non-final class; implicitly-unwrapped optional types; global-actor isolation;
compiler-synthesized members; members from unrelated extensions; and callables
with more than eight defaulted parameters. A `final` member on a non-final class
is eligible. Whole-declaration availability and SPI are copied to the peer.
Unsupported semantic attributes receive macro diagnostics rather than being
guessed. A nested annotated nominal is supported in a nongeneric struct, class,
or enum; local, generic-context, protocol, actor, and extension nesting is not.
Other unsupported declarations are left out of the generated provider.
The sole variadic exception is a directly visible
`ExpressibleByArrayLiteral` witness, represented by dedicated repeated-element
metadata rather than an ordinary callable registration. Its automatic trampoline
is capped at 32 elements; an explicitly trusted array-backed adapter may be
unbounded.
See
[Safety and limitations](Safety.md) for lexical-context and host-execution limits.
