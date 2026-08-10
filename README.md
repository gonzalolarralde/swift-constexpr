# ConstExpr

ConstExpr is an experimental SwiftSyntax source rewriter that evaluates trusted,
registered Swift declarations when every input to an expression is known. It is
not a Swift compiler feature and it does not interpret function bodies. A runner
links the real compiled implementations, invokes them during rewriting, and emits
Swift constants while preserving static types in the contexts it understands.

This is deliberately a best-effort tool, not a substitute for Swift's type
checker or optimizer. Always compile and test rewritten output. Source that needs
constraint-solver context the rewriter does not have is left alone where possible.

The implementation requires Swift 6.3 or newer (`swift-tools-version: 6.3`),
depends on swift-syntax from 603.0.2, and currently targets macOS 11 or newer. See
[the architecture notes](Documentation/Architecture.md) for the value, resolution,
scoping, and trust models.

For local SwiftPM development, add this checkout as a package dependency and the
`ConstExpr` product to the target that defines or runs constant expressions:

```swift
dependencies: [
    .package(path: "../swift-constexpr"),
],
targets: [
    .target(
        name: "MyConstExprDefinitions",
        dependencies: [
            .product(name: "ConstExpr", package: "swift-constexpr"),
        ]
    ),
]
```

Most clients only import `ConstExpr`. A custom `ConstExprRepresentable`
implementation returns `SwiftSyntax.ExprSyntax`, so that target must also declare
swift-syntax 603 as a direct package dependency, add its `SwiftSyntax` product,
and `import SwiftSyntax`. SwiftPM does not make a library's transitive products
directly importable by its clients.

## Defining constant expressions

Annotate synchronous, deterministic declarations in a library:

```swift
import ConstExpr

@ConstExpr
public func increment(_ value: Int) -> Int {
    value + 1
}

@ConstExpr
public struct Label {
    private let value: Int

    public init(_ value: Int) {
        self.value = value
    }

    public func render() -> String {
        "Label \(value)"
    }
}
```

Build a registry explicitly in the module that will drive rewriting:

```swift
import ConstExpr
import MyConstExprDefinitions

public let registry = #constExprRegistry(increment(_:), Label.self)
```

Then rewrite complete source text:

```swift
let result = ConstExprRunner(registry: registry).rewrite(
    source: source,
    fileName: "Input.swift"
)

print(result.source)
for diagnostic in result.diagnostics {
    print(diagnostic)
}
```

For an overloaded free function, disambiguate the registry entry with a cast:

```swift
#constExprRegistry(
    transform(_:) as (Int) -> String,
    transform(_:) as (String) -> String
)
```

An explicit registry is required because an attached Swift macro sees its own
declaration, not an index of every annotation in a module.

For declarations the macro deliberately does not support, an expert caller can
build the same metadata manually. The callback receives an optional receiver and
one optional value per declared parameter; omitted default arguments arrive as
`nil`:

```swift
let incrementRegistration = ConstExprRegistration(
    name: "increment",
    kind: .function,
    parameterLabels: [nil],
    parameterTypes: [Int.self],
    resultType: Int.self
) { _, arguments in
    guard arguments.count == 1, let argument = arguments[0] else {
        throw ConstExprValueError.malformedCollection("missing increment argument")
    }
    return ConstExprValue(try argument.require(Int.self) + 1)
}

let registry = ConstExprRegistry(incrementRegistration)
```

Manual descriptors, throwing flags, source type spellings, and invocation code
are trusted semantic claims; prefer macro-generated adapters when possible.

The generated adapters currently cover:

| Annotation target | Generated registrations |
| --- | --- |
| Free function | A synchronous, nongeneric function with supported value parameters and either no throwing effect or ordinary untyped `throws` |
| Global `let` | One file-scope immutable identifier binding |
| `struct`, `class` | Explicit accessible initializers, nonmutating/nonconsuming methods, static/instance nonlazy properties with explicit supported value types and ordinary getters, read-only instance subscripts, and a directly declared array-literal witness |
| `enum` | The same members plus cases with or without associated values |

Private stored state does not need to be registered. A public method can use it
normally when the generated adapter invokes the compiled method. A member whose
access is lower than the annotated nominal's generated provider is not exposed as
a registration. Members declared only in unrelated extensions and
compiler-synthesized initializers are not visible to the attached macro. On a
non-final class, instance methods, properties, and subscripts must themselves be
`final`; `dynamic` members are always skipped because dispatch could select an
unregistered implementation. Effectful, mutating, or consuming getters are also
skipped.

Availability and SPI attributes on the directly annotated declaration are copied
to its generated peer. An individual nominal member with its own availability or
SPI constraint is not registered because the shared provider cannot reproduce that
member-only context; member-level availability produces a warning. Global-actor
members are likewise omitted.

Because a syntax macro cannot resolve whether an arbitrary attribute is a custom
global actor or a declaration-transforming macro, declaration attributes use a
small allowlist. An unsupported semantic attribute rejects a directly annotated
declaration; an affected nominal member is omitted with a warning. Use a manual
registration when the attribute's behavior is known to be safe.

Generated peers deliberately qualify support types through `_ConstExprRuntime` so
ordinary names such as `ConstExprValue` can be shadowed safely. `_ConstExprRuntime`
itself is reserved: do not declare a competing type or value with that name in a
scope where either ConstExpr macro expands.

## Evaluation model

The evaluator can carry a registered struct, class, or enum as an opaque runtime
value even when that intermediate value cannot be written as a Swift literal. For
example, a fully registered chain can collapse to its final result:

```swift
Foo().bar.blah() // becomes "5"
```

It also propagates simple immutable bindings and performs partial folding:

```swift
let value = increment(1)       // let value = 2
let result = value * 3         // let result = 6
unknown(increment(value))      // unknown(3)
```

Unknown subexpressions are normal and remain in source, although independently
known descendants may still fold. Ambiguous overloads, thrown evaluations, invalid
constant arithmetic, registry collisions, and parser recovery are returned as
structured diagnostics.

Expected-type context also drives Swift's leading-dot construction syntax. A
registered initializer can resolve `.init(...)`, and registered static members can
resolve contextual factories and values such as `.library(...)` or `.dynamic`.
The contextual owner must match the registration's owner exactly; a factory on an
unrelated type is never selected merely because it returns the desired result.
Labels, defaults, literal conversions, and overload ranks are then checked in the
usual way. If the context is absent or more than one best candidate remains, the
source is retained for the Swift compiler.

A custom `ExpressibleByStringLiteral`, `ExpressibleByIntegerLiteral`,
`ExpressibleByFloatLiteral`, or `ExpressibleByBooleanLiteral` type can receive a
source literal when its conformance and corresponding literal initializer are both
in an annotated primary declaration. ConstExpr verifies the linked conformance,
its associated literal type, and the exact registered initializer shape before it
executes anything. Built-in arrays recursively provide element context, so a
`[Dependency]` can be written as `["Core", "Logging"]` when `Dependency` has a
registered string-literal initializer. `Array` and `Set` have unlimited standard
adapters through the same array-literal path, including PackageDescription-style
trait sets.

User-owned array-literal types are supported too. When an annotated primary
declaration directly names `ExpressibleByArrayLiteral` and contains exactly one
eligible `init(arrayLiteral:)` witness, the macro generates an adapter for it:

```swift
@ConstExpr
struct SegmentList: ExpressibleByArrayLiteral {
    init(arrayLiteral elements: Segment...) { /* ... */ }
    init(elements: [Segment]) { /* ... */ }
}
```

Stable Swift cannot safely splat a runtime `[Segment]` into a variadic witness,
so the generated witness trampoline supports zero through 32 elements. A larger
literal is retained for the compiler with a diagnostic. A library author with an
array-backed construction path can register an unbounded trusted adapter instead:

```swift
ConstExprRegistration.arrayLiteral(
    result: SegmentList.self,
    element: Segment.self
) { elements in
    SegmentList(elements: elements)
}
```

A missing expected type, unknown element, or ambiguous custom adapter leaves the
outer literal unresolved; independently safe child rewrites may still be
retained. An extension-only literal conformance or witness remains compiler work
because the attached macro cannot discover it.

An adapter for an ordinary `throws` declaration executes only when the source
call is covered by `try`, `try?`, or `try!`. A call missing that required marker
is retained instead of being turned into a constant that accidentally repairs
invalid Swift. If the linked invocation actually throws, the call is retained and
an `evaluation-threw` diagnostic is reported. A `try` outside a nested closure does
not authorize an unmarked throwing call inside that closure. Throwing calls also
remain in catch-bearing `do` bodies, inferred-throwing closures, and declarations
without a compatible plain `throws` boundary (`rethrows` and typed throws remain
conservative), so folding cannot erase a
`catch`, an inferred function effect, or a required compiler diagnostic. Locally
handled `try?` and `try!` expressions remain eligible.
Likewise, a `try`, `try?`, or `try!` around an otherwise foldable nonthrowing
registration is retained so Swift can still diagnose the redundant marker.

“Unknown” is a syntactic decision. ConstExpr does not load a Swift module index or
run the constraint solver for the input file. In particular, it cannot infer the
parameter context or overload rules of an arbitrary unregistered declaration.
Source-visible declarations are treated as conservative shadows: an unqualified
source function blocks a registration of that name, and an extension member in the
input blocks registered members with the same matching owner spelling and name even
when its written signature differs; an unqualified extension owner matches by
basename. Imported overloads that are absent from the registry are not visible at
all. For an imported overloaded API that will be folded, include every competing
overload that could win at those call sites; the same completeness rule applies to
imported operator overloads. Compile-time validation of rewritten output remains
required.

Only simple immutable bindings propagate. Initializers inside `var` declarations
can still be simplified, but later reads of the mutable variable are unknown.
Parameters, captures, loop and catch patterns, local declarations, and nested
bindings conservatively shadow outer constants.

The runner does not execute registered calls while traversing `if`/`switch`
bodies, loops, guard conditions, catch clauses, or conditional-compilation
branches because it does not prove which path or iteration runs. Syntax-local
children may still simplify. Macro and attribute arguments remain syntax. A
declaration carrying attributes—including a function, initializer, subscript,
nominal type, protocol, extension, deinitializer, or accessor—is left opaque; an
attributed variable's initializer is also retained because an attached macro may
inspect its original syntax. Unattributed accessors can use their declared result
type as folding context. An outer call with a trailing closure is not matched as a
registered call. Inside a closure with no explicit result type, only folds that do
not depend on the unknown caller-provided result context are attempted;
syntactically detected result-builder calls are retained as a whole.

Static type is part of every known value. Results whose type is not Swift's
default literal type use explicit context:

```swift
fiveAsInt64()       // (5) as Swift.Int64
letter()            // ("x") as Swift.Character
maybeValue(false)   // nil as Int?
```

This also makes overload resolution conservative. A source integer literal can
be decoded for an `Int64` parameter, while a computed `Int` result is never
silently widened. Explicit binding annotations provide useful context:

```swift
let value: Int64 = 1
let rendered = acceptsInt64(value)
```

Arrays, sets, dictionaries, optionals, and tuples can be carried when their
elements and concrete types are known. Heterogeneous literals whose common type
would require Swift constraint solving are retained conservatively. An opaque
annotated type can be stored in a `let` and used by a later registered property,
method, or subscript. Direct structural tuple-literal arguments decode at arities
two through four. Other tuple shapes can flow between registrations only when an
exact boxed runtime tuple already exists, such as the result of a registered call.

A custom terminal type may implement `ConstExprRepresentable`, but its returned
syntax must be one complete expression. ConstExpr reparses it as the initializer of
one synthetic binding and rejects parser recovery, extra bindings, or additional
statements. The implementation is responsible for preserving the declared static
type and value; invalid output causes the original call to remain.

Known optional operations preserve laziness. A statically nil optional chain does
not evaluate its member arguments, `??` does not evaluate its unselected side, and
force-unwrapping a known value materializes the wrapped value. A known nil force
unwrap remains in source and reports `forced-unwrap-of-nil`.

## Operators

Swift's standard operator table is folded before evaluation, so precedence and
associativity match parsed Swift rather than a hand-written expression grammar.
The runtime handles a focused set of checked and wrapping integer arithmetic,
shifts and bitwise operations, floating-point arithmetic, Boolean logic,
comparisons, and homogeneous string or array concatenation. Short-circuit and
conditional operators do not execute an unselected registered call.
Structural `==` and `!=` fold only when built-in `Equatable` support can be
established recursively for every optional, array, dictionary, or tuple element;
erased and non-Equatable structures remain unchanged.

Custom operators can use the same registry without a macro adapter:

```swift
let comparison = ConstExprRegistration.infixOperator(
    "<=>",
    left: Int.self,
    right: Int.self,
    result: Int.self,
    precedenceGroup: "ComparisonPrecedence",
    associativity: .none
) { left, right in
    left < right ? -1 : (left == right ? 0 : 1)
}

let registry = ConstExprRegistry(comparison)
```

The real operator implementation must still be linked like any other registered
API. If its declaration is imported rather than repeated in the input, the runner
adds a temporary parser declaration from the registration metadata. Real source
declarations and the standard operator table take priority. When synthesis is
needed, the non-nil precedence and associativity claims across overloads for one
fixity and symbol must not conflict; conflicts are diagnosed without executing the
operator. A named infix precedence group must be standard or declared in the
input because the registry cannot reconstruct an imported group's relative
ordering rules. Associativity belongs to that group. A supplied registration
associativity is checked against the group's authoritative value; it never changes
how Swift groups the expression. A real declaration in the input or an entry
already present in Swift's standard operator table is authoritative, and its
registration metadata is ignored. Set `isThrowing: true` for a throwing operator.
The runner then requires a source-level `try`, `try?`, or `try!`, just as it does
for a throwing macro-generated declaration.

## Diagnostics and limits

`rewrite(source:fileName:)` is best-effort: ordinary unknown expressions are
quiet, while detected unsafe or surprising failures are visible in the result.
Diagnostics include a stable code, severity, message, file, line, and column.
When syntax supplies an absolute position, they also include a zero-based UTF-8
byte offset into the original source, including any leading UTF-8 byte-order mark.
Examples include
`ambiguous-overload`, `evaluation-threw`, `division-by-zero`,
`integer-overflow`, `registry-collision`, and `parse-error`.

The runner preserves a leading UTF-8 byte-order mark and existing CRLF trivia.
The example CLI accepts only valid UTF-8 and preserves those bytes for both files
and standard streams; it does not normalize line endings.

`ConstExprRewriteOptions` bounds evaluator node count and recursion depth. The
defaults are 10,000 evaluated expression nodes and a depth of 256; a configured
value below one is normalized to one. These limits bound expression-evaluator
work; the runner still has to parse and traverse the source, and the limits cannot
interrupt arbitrary annotated code.

## Safety contract

`@ConstExpr` code runs in the rewriting process. Annotating a declaration promises
that it is deterministic, terminating, nonmutating, and safe to execute during a
build. ConstExpr does not sandbox registered code and cannot prevent an annotated
call from trapping, exiting the process, looping forever, accessing files or the
network, or producing another side effect.

Treat both the registry and input source as trusted build inputs. An input file can
choose a registered declaration and literal arguments, thereby causing linked code
to run. Results are produced on the host running the rewriter, so declarations must
also avoid host-dependent time, locale, environment, filesystem, and architecture
behavior when output needs to be reproducible.

Registrations and registries are `Sendable`, and manual invocation/operator
callbacks are `@Sendable`. Any captured state must therefore be `Sendable` and
safe for concurrent access. This type-level contract does not make the linked
declaration pure or thread-safe, and the runner does not serialize calls made by
separate rewrites.

Manual static-type descriptors are trusted semantic metadata. In particular,
erased existential metatypes do not reveal class bounds or arbitrary protocol
conformance, so a manual descriptor's class-bound flag and source-type predicate
cannot be independently proved by the runtime. The macro emits compiler-checked
witnesses; manual registrations must keep these claims consistent with Swift.
Manual registrations must also set `isThrowing: true` whenever their callback
represents a throwing declaration or operator; the default is `false`.

## Package.swift and consumer workflow

`Examples/LibraryAuthor` contains a bounded, annotated PackageDescription facade
plus a normal const-enabled library and two exported registry-provider products.
`Examples/Consumer` is a separate stock Swift package. Its `build.sh` constructs a
consumer-specific rewrite driver, stages and rewrites both the manifest and source
files, validates the staged manifest with SwiftPM, and builds it without changing
the checked-in package:

```sh
cd Examples/Consumer
./build.sh --run
```

This external bootstrap is necessary because SwiftPM evaluates `Package.swift`
before build-tool plugins run or a dependency graph exists. The facade is pinned
to a deliberately small API surface; it does not make every SwiftPM manifest or
extension-defined PackageDescription API automatically evaluable. See
[Package manifest evaluation](Documentation/PackageManifests.md) and the
[example walkthrough](Examples/README.md) for the supported construction and
literal rules, plugin boundary, and staging flow.

## Current limitations

The initial implementation intentionally excludes async, `rethrows`, typed
`throws(E)`, and generic declarations; `Void`, `Never`, opaque, or function-valued
results; `inout`, ownership-qualified, ordinary variadic, autoclosure, and closure-valued
parameters; mutating or consuming methods; mutation/data-flow analysis; and
compiler-complete overload resolution. Generated type providers inspect explicit
declarations in the primary type body; synthesized members, unrelated extensions,
and private callable members are not automatically registered.
The narrow variadic exception is a directly declared `ExpressibleByArrayLiteral`
witness, whose generated adapter is limited to 32 elements unless an explicit
array-backed adapter is registered.
An annotated nominal may be nested in a nongeneric struct, class, or enum, and is
then registered with its qualified type spelling. Local nominals and nominals
nested in generic, protocol, actor, or extension contexts are unsupported.

Within those direct nominal members, generated adapters owner-qualify `Self` and
owner-local type names. They invoke the original declaration with absent default
arguments still omitted, preserving defaults that rely on declaration context.
Caller-location defaults, implicitly-unwrapped optional types, and
global-actor-isolated declarations are explicitly unsupported and receive macro
diagnostics. Parameterized existential types such as `any Collection<Int>` are
also rejected while the package retains its macOS 11 deployment target, because
their runtime metatype support starts on macOS 13. Plain existentials such as
`any CustomStringConvertible` are supported. Generated callables support at most
eight defaulted parameters.
Attach `@ConstExpr` once to a nominal rather than to its individual members, and
use the manual registration factories for custom operators. Imported operator
declarations do not have to be repeated in every input: the runner can synthesize
a temporary parser declaration from consistent registration metadata. Infix
registrations should name a standard precedence group or one declared in the
input; conflicting metadata is diagnosed and never executed.

See [Safety and limitations](Documentation/Safety.md) for the trust boundary and
the distinction between syntax-level proof and Swift semantic type checking.

## Example executable

The package includes a runner linked to the example registry:

```sh
swift run swift-constexpr-example Input.swift
swift run swift-constexpr-example --output Rewritten.swift Input.swift
cat Input.swift | swift run swift-constexpr-example -
swift run swift-constexpr-example --fail-on-diagnostics Input.swift
```

This executable is intentionally registry-specific. Applications with their own
annotated libraries build a small executable around their own registry. It exits
with status `2` when `--fail-on-diagnostics` sees any note, warning, or error;
the rewritten UTF-8 source is still emitted before that status is returned.
Without the flag, diagnostics are printed to stderr and a completed rewrite exits
successfully. Unexpected internal failures use status `1`, invalid arguments `64`,
input failures `66`, and output failures `74`. Use `--output -` for stdout and `--`
before an input path beginning with `-`.
