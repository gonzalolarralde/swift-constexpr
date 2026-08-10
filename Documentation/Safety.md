# Safety and limitations

ConstExpr executes linked Swift code while rewriting source. `@ConstExpr` is a
trust declaration, not a purity checker. The runtime does not sandbox adapters,
start a restricted subprocess, or impose a timeout on an individual invocation.

## Trusted inputs

Trust both sides of a rewrite:

- The registry selects which linked declarations are executable.
- The input source selects a registration by spelling a call and supplies the
  literal or previously-derived arguments.

Do not expose a registry containing privileged operations to arbitrary source.
An annotated declaration must terminate and must not read or mutate files, make
network requests, inspect secrets, exit the process, depend on global mutable
state, or otherwise have an externally visible effect. The syntax node/depth
limits bound the expression evaluator; they cannot interrupt linked code that hangs
or traps.

Registrations and registries can cross concurrency domains. Their manual
invocation and operator callbacks are `@Sendable`, so captured state must itself
be `Sendable` and safe for concurrent access. That signature is a transfer-safety
boundary, not a purity guarantee: separate runners can still call the same linked
declaration concurrently, and ConstExpr does not add synchronization around it.
`ConstExprRunner` is itself `Sendable`; each `rewrite` creates local traversal
state, but linked declarations and callback captures remain shared resources.

Manual recursive static-type descriptors are also part of the trust boundary.
The runtime validates structural shape and rejects a returned payload that is not
runtime-compatible with its claimed top-level metatype. It cannot, however,
recover an erased existential's class-bound constraint or prove an arbitrary
manual source-type predicate. Macro-generated witnesses are compiler-checked;
manual class-bound flags, predicates, and source type spellings must accurately
describe the linked declaration. Manual registrations must also set `isThrowing`
truthfully; a throwing function or operator incorrectly left at the default
`false` bypasses the runner's source-level `try` gate.

For reproducible builds, declarations must also be independent of host time,
locale, environment variables, random state, filesystem contents, process state,
and architecture-specific behavior. Evaluation happens on the host running the
rewriter, which need not be the eventual deployment target.

## What “known” means

The runner performs syntax-directed evaluation with registry metadata. It does
not invoke the Swift type checker, load arbitrary declaration interfaces, or run
the constraint solver for the input file. A value is known only when the runtime
can establish its receiver, arguments, static type, and unique registration from
that information.

This supports registered calls, opaque registered member chains, simple immutable
bindings, explicitly typed literals, structural values, and a focused set of
operators. It does not establish whole-program equivalence. Context supplied only
by an unknown outer declaration or by constraint-solver inference may be unavailable
to a local fold. Compile and test the rewritten source before treating it as a
build artifact.

Optional, Array, Dictionary, Set, and tuple shapes are intrinsic runtime
structures, not executable registrations for every specialization. Sugar and
generic spellings canonicalize recursively, and materialization still requires
known components plus the language constraints (for example `Hashable` keys and
set elements). A user-defined `Optional`/`Array` shadow blocks that intrinsic path.

Source declarations are treated as conservative shadows when they are visible:
an unqualified function declaration blocks a registration of the same name, and a
source extension member blocks every registered member with the same matching
owner spelling and name. An unqualified extension owner matches by basename. This
can deliberately under-fold. The inverse cannot be detected: imported overloads
absent from the registry are invisible. Include every imported overload, including
operator overloads, that could win at a call site ConstExpr is expected to fold.

Parser errors are returned without rewriting recovered syntax. Semantic errors
are different: SwiftSyntax can parse code that Swift's type checker later rejects.
The runner cannot report all of those errors and is not intended to repair them.
Hosts that may skip compilation should use certifying terminal evaluation. It
returns a structured fallback unless every active top-level binding is known and
the requested value has the expected linked type. Unknown availability domains,
unsupported statements, ambiguity, and evaluation diagnostics are misses; the
host should compile the untouched original source and let Swift issue diagnostics.

## Macro boundary

Generated adapters currently target synchronous, nongeneric declarations with
ordinary value parameters. Async, `rethrows`, and typed `throws(E)` declarations;
`Void`, `Never`, opaque, and function-valued results; ordinary variadics; `inout`,
ownership-qualified, autoclosure, and closure-valued parameters; mutating or
consuming methods; effectful accessors; and writable subscripts are outside the
supported adapter subset. A nominal annotation sees explicit members in its
primary body. Synthesized members and unrelated extensions are not discovered
automatically. Annotating an extension with `@ConstExprMembers` collects all of
its eligible immediate members, while a direct annotation can still opt in one
declaration with strict diagnostics. `@ConstExprIgnored` is the explicit safety
escape hatch for a declaration that bulk collection would otherwise accept. A
member whose access is lower than the generated nominal provider is not exposed.
Automatic scalar-literal evaluation requires both the
linked conformance and a registered exact literal initializer. A nominal
annotation discovers a witness in its primary declaration; an eligible extension
initializer can instead be annotated directly. An unannotated extension witness
remains unresolved because executing it would bypass the registry trust boundary.
The narrow variadic exception is an annotated primary declaration that directly
conforms to `ExpressibleByArrayLiteral` and exposes exactly one eligible
`init(arrayLiteral:)` witness. Its compiler-checked automatic adapter supports at
most 32 elements. Larger literals, ambiguous adapters, and literals containing an
unknown element remain compiler work. `Array` and `Set` use standard unlimited
adapters through the same registration path; a library author may explicitly opt
a custom type into an unbounded array-backed
`ConstExprRegistration.arrayLiteral(..., build:)` adapter.
Self-contained literal defaults use a linear adapter and are not capped at eight.
Nontrivial defaults use native omission branches through eight positions; larger
cases require a checked manual label-keyed adapter. Operator functions use manual
registrations.
Annotated nominals may be nested in nongeneric structs, classes, or enums, or
directly in a nongeneric, unconstrained extension. Local nominals and nominals
nested in generic, protocol, actor, or constrained-extension contexts are
unsupported. A generic nominal bulk annotation produces no provider.

Properties require explicit supported value-type annotations. Lazy properties and
mutating/consuming getters are skipped, and subscript adapters are limited to
read-only instance subscripts. A `dynamic` member is skipped. Instance methods,
properties, and subscripts on a non-final class must themselves be `final`, because
an overridable adapter could dispatch to an implementation that was never
registered. Initializers and type members still follow the other ordinary filters.

Generated registrations record introduced/deprecated/obsoleted availability and
`_disfavoredOverload`, including eligible members collected by a nominal provider.
A certifying runner requires a matching availability context before it can use a
constrained overload set. Deprecated registrations
remain compiler work so their warnings are not erased. Package-scoped peers erase
their registration-array type so an internal ConstExpr import and generated
provider do not leak into the public interface. Whole-nominal providers silently
omit unconditionally unavailable members and deprecated members that cannot be
invoked warning-free. An eligible deprecated static stored `let` on a struct or
enum can instead use a copied, contextually typed `.init(...)` expression made
only from recursively self-contained constants. Its availability cutoff is still
enforced. Class owners are excluded because reconstructing a stored singleton
could change identity or lazy-once semantics. Unsafe SPI and global-actor contexts
remain excluded when their access or isolation cannot be reproduced.

The macro also cannot semantically resolve arbitrary custom attributes. It keeps
a small allowlist of attributes whose effects are safe for generated peers;
other attributes reject a directly annotated declaration or cause an affected
bulk member to be omitted silently. A manual registration is the escape
hatch when the attribute's isolation and transformation behavior is known.

Macro-generated source qualifies runtime support through `_ConstExprRuntime`.
Client declarations may shadow ordinary names such as `ConstExprValue`, but the
name `_ConstExprRuntime` itself is reserved in every macro-expansion scope.

Ordinary untyped `throws` functions, initializers, and methods are supported.
Their registration records the throwing effect, and the runner invokes them only
when the parsed call is covered by `try`, `try?`, or `try!`. This preserves a
missing-`try` compiler error instead of silently replacing the invalid call. The
authorization stops at closure boundaries: an outer `try` does not excuse a
missing `try` inside a nested closure. Manual throwing operator registrations must
set `isThrowing: true` and follow the same rule. Catch-bearing `do` bodies,
inferred-throwing closures, nonthrowing declarations, and default arguments retain
plain-`try` registered calls when removing them could erase a catch, inferred
effect, or compiler error. `rethrows` and typed-throws declarations are conservative
for the same reason. Locally handled `try?` and `try!` calls remain eligible.
A redundant `try`, `try?`, or `try!` around a nonthrowing fold remains in source
so Swift's diagnostic is preserved.

For generated members, `Self` and owner-local type names are qualified in the
peer. Nontrivial absent defaults remain absent when the adapter calls the original
declaration; self-contained literal defaults may be copied and passed explicitly.
Caller-location defaults are still rejected because the
rewriter is a different call site. Implicitly-unwrapped optional types and
global-actor-isolated declarations are also explicitly unsupported. Parameterized
existentials such as `any Collection<Int>` are rejected on the package's macOS 11
baseline because the required runtime metatype support begins on macOS 13; plain
existentials remain supported. Treat the corresponding macro diagnostic as a hard
boundary rather than ignoring it.

## Source preservation

Internal comments and deferred syntax such as macro/attribute arguments and
structured control flow are handled conservatively. Within supported lazy
expressions (`&&`, `||`, `??`, and ternary), an unselected registered operation is
not executed. Registered calls are not executed while traversing `if`/`switch`
bodies, loops, guard conditions, catch clauses, or conditional-compilation
branches. A declaration carrying attributes—including a function, initializer,
subscript, nominal type, protocol, extension, deinitializer, or accessor—remains
opaque; an attributed variable's initializer is also retained because an attached
macro may inspect its syntax. Unattributed accessors may use their declared result
type as folding context. Implicit closure bodies without an explicit result type
are evaluated without assuming the caller's unknown result context; only
context-independent descendants may fold. Calls recognized
syntactically as result-builder entry points remain wholly opaque. These rules
reduce accidental source changes, but the output is still regenerated SwiftSyntax
and should be reviewed like generated code.

Custom `ConstExprRepresentable` implementations are responsible for returning a
valid Swift expression with the same static type and value. Prefer an atomic
literal, initializer call, or explicitly parenthesized expression. A renderer that
depends on surrounding precedence can change meaning when embedded in a larger
expression. Before insertion, ConstExpr reparses the rendered text and requires
it to be the sole initializer expression in exactly one synthetic binding.
Recovered, malformed, multi-binding, or multi-statement output is rejected and the
original source remains. Parser acceptance does not prove semantic type or value
equivalence; those remain promises made by the conformance.

`rewrite(source:fileName:)` preserves a leading UTF-8 byte-order mark and CRLF
trivia. Syntax-backed diagnostic offsets are zero-based UTF-8 byte positions in
the original source, so multibyte scalars, a byte-order mark, and CRLF each count
by their encoded byte length. The example CLI rejects non-UTF-8 input and preserves
the accepted input's byte-order mark and line endings.

## Operational recommendations

1. Keep the registry small and explicit.
2. Annotate pure total functions, not convenient wrappers around I/O or state.
3. Run the rewriter in a build step with bounded external process time.
4. Compile and test the rewritten output.
5. Use `--fail-on-diagnostics` in automation and retain the original source as the
   authoritative input.
