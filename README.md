# ConstExpr

ConstExpr evaluates explicitly trusted Swift declarations when every input is
known. It can replace a call with a Swift constant, power an inline `#evaluate`
macro, or return a typed global value to a host application without compiling
and running the input file.

```swift
@ConstExpr
func increment(_ value: Int) -> Int {
    value + 1
}
```

That declaration enables this rewrite:

```swift
let answer = increment(41)
// becomes: let answer = 42
```

ConstExpr is an experimental linked source evaluator, not a Swift interpreter.
It invokes the real compiled implementation of a registered declaration. If it
cannot prove an expression safely, it leaves the source alone or reports a
structured fast-path miss. Swift's compiler remains the authority on the
original or rewritten program.

The package requires Swift 6.3, swift-syntax 603.0.2, and macOS 11 or newer.

## Ship a library-owned macro

A library can use ConstExpr internally without asking its consumers to adopt
ConstExpr's API. The [PacketKit example](Examples/README.md) exposes one library
product with its own types and domain-specific compiler macro:

```swift
import PacketKit

let bytes = #packetConstBytes {
    Packet.UInt64(0x0102030405060708, order: .bigEndian)
    Packet.UInt8(2)
    Packet.Bytes([16, 32])
}
// Generates [1, 2, 3, 4, 5, 6, 7, 8, 2, 16, 32] at compile time.
```

The consumer depends only on PacketKit and builds normally with SwiftPM. The
library author owns the annotations, registry, and a thin compiler plugin that
delegates to `ConstExprBuilderMacroSupport`. With `#packetConstBytes`, an
unresolved input is a build error. Otherwise, supported mixed bodies fold their
known fields and retain dynamic computation; unsupported bodies fall back to
ordinary Swift. The CLI example generates an entire looping, two-frame GIF
during macro expansion and only writes those constant bytes at runtime:

```sh
swift run --package-path Examples/Consumer PacketDemo /tmp/packet.gif
```

ConstExpr remains a transitive dependency, but the consumer needs no direct
ConstExpr dependency, import, registry, or custom build step. The rest of this
guide explains the APIs used by library authors and evaluator hosts.

### Mix constants with runtime fields

Use `#packetBytes` when only part of a builder body is known:

```swift
func message(opcode: UInt8, payload: [UInt8]) -> [UInt8] {
    #packetBytes {
        Packet.UInt16(0xCAFE, order: .bigEndian)
        Packet.UInt8(opcode)
        Packet.Bytes(payload)
        Packet.UInt16(0xBEEF, order: .bigEndian)
    }
}
```

Both the header and trailer become literal bytes; the dynamic fields and final
assembly remain runtime work. Known arguments inside otherwise dynamic calls
can fold too. The expansion preserves dynamic evaluation order and single
evaluation, and does not pass folded components through `buildExpression`
again. If nothing folds or safe partial output is unavailable, the original
runtime builder is retained. Strict mode rejects every partially dynamic result.

`ConstExprBuilderMacroSupport` supports synchronous, nonthrowing expressions
and immutable local bindings. Libraries can opt into known Boolean `if`/`else`
and optional branches with `supportsBranches: true` and registered
`buildEither`/`buildOptional` hooks. Unknown conditions retain the complete
runtime builder, preserving lazy selection; loops are not folded.
PacketBuilder itself has no conditional or loop-building hooks. Library authors
supply the registered builder hooks and runtime fallback; the
[PacketKit guide](Examples/README.md#the-library-authors-view) shows the helper
configuration and the public/model/macro target split. PacketKit re-exports its
model using the underscored `@_exported` attribute; public type aliases remain
an alternative when a narrower surface is preferred.

## Add ConstExpr to a package

For local development, add the checkout and the `ConstExpr` product:

```swift
// Package.swift
dependencies: [
    .package(path: "../swift-constexpr"),
],
targets: [
    .target(
        name: "MyLibrary",
        dependencies: [
            .product(name: "ConstExpr", package: "swift-constexpr"),
        ]
    ),
]
```

Annotated models only need `import ConstExpr`. Hosts using `ConstExprRunner`,
source evaluation/rewriting, or `ConstExprRepresentable` must depend on and
import the `ConstExprEvaluation` product instead; it re-exports the base module.
Custom renderers also need a direct `SwiftSyntax` dependency and import.

### Embedded Swift

The same annotated models compile in Embedded mode. `ConstExpr` has no ordinary
SwiftSyntax dependency: its attached macros select no-op implementations under
`hasFeature(Embedded)`, and its host-only registry/value support is excluded.
No Foundation, evaluator, generated registration peers, or dummy registry is
compiled into the device module. The compiler plugin remains a host executable.
Keep `ConstExprEvaluation` and `ConstExprMacroSupport` in host-only targets;
consumer expression macros can still evaluate annotated host models while
compiling Embedded firmware.

## Declare what can be evaluated

Use `@ConstExpr` on a function:

```swift
import ConstExpr

@ConstExpr
public func makeGreeting(name: String) -> String {
    "Hello, \(name)!"
}
```

That declaration enables:

```swift
let greeting = makeGreeting(name: "Ari")
// becomes: let greeting = "Hello, Ari!"
```

Use `@ConstExpr` once on a type to collect every eligible declaration in its
primary body. Initializers, methods, static methods, properties, enum cases,
and read-only subscripts are included when their signatures are supported:

```swift
@ConstExpr
public struct Label {
    private let value: Int

    public init(_ value: Int) {
        self.value = value
    }

    public static func doubled(_ value: Int) -> Label {
        Label(value * 2)
    }

    public var text: String {
        "item-\(value)"
    }
}
```

That one annotation enables the whole chain:

```swift
let text = Label.doubled(4).text
// becomes: let text = "item-8"
```

Bulk collection silently skips declarations that cannot be adapted, such as
generic, asynchronous, mutating, variadic, or dynamically dispatched members.
Use `@ConstExprIgnored` when a declaration is syntactically eligible but unsafe
to execute during a build:

```swift
import Foundation

@ConstExpr
public struct BuildValues {
    public static var formatVersion: Int { 3 }

    @ConstExprIgnored
    public static var currentDirectory: String {
        FileManager.default.currentDirectoryPath
    }
}
```

This enables `BuildValues.formatVersion`, but intentionally leaves
`BuildValues.currentDirectory` to normal Swift execution.

An unrelated extension is not visible to the type's attached macro. Annotate
the extension once to collect its eligible immediate members:

```swift
@ConstExprMembers(named: "Formatting")
extension Label {
    public func repeated(_ count: Int) -> String {
        String(repeating: text, count: count)
    }
}
```

Direct member annotations remain useful when you want an unsupported
declaration to produce a macro diagnostic instead of being silently omitted.

## Build a registry

Attached macros generate registration peers beside declarations, but a Swift
macro cannot enumerate every annotation in a module. A host therefore declares
the exact API surface it trusts:

```swift
import ConstExpr
import MyLibrary

let labelRegistry = #constExprRegistry(
    for: Label.self,
    extensions: ["Formatting"]
)

public let registry = #constExprRegistry(
    makeGreeting(name:)
).appending(contentsOf: labelRegistry)
```

The root type selects the provider generated by its nominal annotation. Each
extension name selects the single provider generated beside that extension; a
misspelled name becomes a compiler error because no owner-scoped provider with
that name exists. Free functions and individually annotated declarations can
still use the declaration-list form. Cast an overloaded function to select its
declaration:

```swift
let registry = #constExprRegistry(
    makeGreeting(name:),
    transform(_:) as (Int) -> String,
    transform(_:) as (String) -> String
)
```

The registry is both a lookup table and a trust boundary. Only linked,
registered declarations can execute.

### Generate a registry from an annotated target

When a host intentionally trusts every annotated provider in one library
target, the `GenerateConstExprRegistry` command plugin can maintain that list.
It uses the same annotation expansion and eligibility rules as the compiler
macros, without building or executing the selected library.

For PacketKit, run from this repository's root:

```sh
swift package --package-path Examples/LibraryAuthor \
  --allow-writing-to-package-directory generate-constexpr-registry \
  --module PacketKitModel --output-target PacketKitMacros \
  --registry-name PacketKitRegistry
```

This writes `PacketKitMacros/PacketKitRegistry.generated.swift` inside its
source directory. The handwritten macro uses `PacketKitRegistry.value`.
Check in the generated file; consumers still build normally. Rerun after
changing annotations or API signatures, and append `--check` in CI to fail on
missing or stale output without changing package files. Unchanged output is
not rewritten. SwiftPM's write permission applies to the command as a whole,
including its read-only check mode.

Both targets must belong to the package where the command runs. The output
target must directly depend on the source target (unless they are the same),
and have the `ConstExpr` and imported-module dependencies needed by the
generated source. The command does not edit `Package.swift`. Cross-target
providers and their enclosing types must be package/public; internal providers
can be collected with the same target for both options. Without
`--registry-name`, the name is `<SourceModule>GeneratedRegistry`.

Discovery handles nominal providers, explicitly annotated nested types,
individual functions/properties/initializers/subscripts, and unnamed or named
`@ConstExprMembers` extensions. Overloads use typed selectors; members already
included in their nominal provider are not duplicated. Unsupported members of
bulk annotations keep the macros' existing omission rules. Explicit annotations
that cannot produce an accessible provider are errors.

This is a source-only command, not whole-module type checking. Conditional
providers/imports and availability- or SPI-gated providers require a manually
guarded registry. Other macros' expansions are not scanned; build-generated
providers are not supported. Swift still type-checks all emitted selectors.
Only the matching generator-owned file can be overwritten, never a handwritten
file. This automates aggregation, not purity inference or implicit registration.

## Rewrite Swift source

Create a runner with the registry and give it complete Swift source:

```swift
import ConstExprEvaluation

let source = #"""
let greeting = makeGreeting(name: "Ari")
let label = Label.doubled(4).text
unknown(makeGreeting(name: "Bo"))
"""#

let result = ConstExprRunner(registry: registry).rewrite(
    source: source,
    fileName: "Input.swift"
)

print(result.source)
```

The result is:

```swift
let greeting = "Hello, Ari!"
let label = "item-8"
unknown("Hello, Bo!")
```

An unknown parent does not prevent an independently known child from folding.
Ambiguous overloads, invalid constant arithmetic, thrown evaluations, registry
collisions, and parser recovery remain source and produce structured
diagnostics.

ConstExpr also propagates immutable bindings:

```swift
let base = increment(20) // let base = 21
let answer = base * 2    // let answer = 42
```

Mutable bindings do not propagate, and ConstExpr does not perform assignment or
control-flow analysis.

## Evaluate inline with `#evaluate`

An application or library can expose a companion expression macro backed by
its concrete registry:

```swift
let answer: Int = #evaluate {
    let base = increment(20)
    base * 2
}
```

When evaluation succeeds, the macro expands to:

```swift
let answer: Int = 42
```

If the closure captures an unknown value, uses unsupported syntax, selects an
ambiguous overload, or produces a value that cannot be rendered, it expands
silently to the original expression or closure invocation. Swift still
type-checks that fallback, so compiler diagnostics remain authoritative.

Expression macros cannot discover arbitrary declarations in the consumer
module. The library supplies a small companion macro target that links its
registry:

```swift
public struct MyEvaluateMacro: ExpressionMacro {
    public static func expansion(
        of macro: some FreestandingMacroExpansionSyntax,
        in context: some MacroExpansionContext
    ) throws -> ExprSyntax {
        ConstExprEvaluateMacroSupport.expansion(
            of: macro,
            in: context,
            registry: registry
        )
    }
}
```

The application-facing library declares the macro name:

```swift
@freestanding(expression)
public macro evaluate<Result>(_ body: () -> Result) -> Result =
    #externalMacro(module: "MyEvaluateMacros", type: "MyEvaluateMacro")
```

See
[`ConstExprEvaluateExampleMacros`](Sources/ConstExprEvaluateExampleMacros/ConstExprEvaluateExampleMacro.swift)
for a complete companion and
[`ConstExprEvaluateExample`](Sources/ConstExprEvaluateExample/Evaluate.swift)
for its public declaration.

## Use a resolved global as a fast path

Source rewriting is not the only useful output. A host can evaluate a named
global binding and receive its linked Swift value directly.

Suppose a configuration library declares:

```swift
@ConstExpr(registrationAccess: .package)
public struct BuildDescription: Codable {
    public let name: String
    public let targets: [String]

    public init(name: String, targets: [String] = []) {
        self.name = name
        self.targets = targets
    }
}
```

This declaration enables a separate source file to construct the real linked
model:

```swift
import BuildModel

let build = BuildDescription(
    name: "Example",
    targets: ["Core"]
)
```

The host can extract `build` without rendering it back into Swift:

```swift
import Foundation

let evaluation = ConstExprRunner(registry: registry).evaluate(
    source: originalSource,
    binding: "build",
    as: BuildDescription.self,
    policy: .certifying,
    fileName: "Build.swift"
)

switch evaluation {
case .success(let build):
    let json = try JSONEncoder().encode(build)
    consume(json)

case .fallback(let reason):
    compileAndRun(originalSource, reason: reason)
}
```

This pattern is useful for declarative configuration files, code generators,
schema definitions, build descriptions, and other systems that normally compile
and execute a Swift file only to obtain one terminal model.

Certifying evaluation is intentionally all-or-nothing. Every active top-level
item must be an understood import or immutable binding, the requested binding
must have the exact requested type, and overload resolution must be unique. A
host that evaluates conditional compilation can pass its already configured
`SourceFileSyntax` to avoid parsing the file again. On any miss, discard
speculative values and compile the untouched original source.

`registrationAccess: .package` is designed for this integration style. The
original public API remains public, while generated providers are package-scoped
and type-erased. A sibling host adapter can consume them without leaking
ConstExpr imports or provider symbols into the library's public interface.

## Specialize declarations the macro cannot adapt

Macro-generated registrations are preferred because Swift checks their function
references and types. A manual registration is useful for a historical API,
host-only bridge, nontrivial default argument, or declaration that deliberately
needs a different construction path.

Use a label-keyed adapter when a declaration has many repeated or defaulted
parameter types:

```swift
let registration = ConstExprRegistration.labelKeyed(
    name: "BuildDescription",
    kind: .initializer,
    ownerType: BuildDescription.self,
    parameterLabels: ["name", "targets"],
    parameterTypes: [String.self, [String].self],
    defaultedParameters: [1],
    resultType: BuildDescription.self
) { receiver, arguments in
    guard receiver == nil else {
        throw ConstExprValueError.malformedCollection("unexpected receiver")
    }
    return ConstExprValue(BuildDescription(
        name: try arguments.require("name", as: String.self),
        targets: try arguments.optional(
            "targets",
            as: [String].self
        ) ?? []
    ))
}
```

Labels, types, defaults, availability, overload preference, and invocation code
are trusted semantic claims. Prefer fallback over an adapter that merely guesses
what Swift would select.

## Literals and structural values

Expected type flows into registered initializers and static members, enabling
Swift's leading-dot syntax:

```swift
let product: Product = .library(name: "Core", type: .dynamic)
```

Scalar literal conversion works for registered literal initializers whose linked
type has the matching `ExpressibleBy…Literal` conformance. Arrays recursively
provide element context, so a registered string-literal element type can enable:

```swift
let dependencies: [Dependency] = ["Core", "Logging"]
```

Optional, Array, Dictionary, Set, range, and tuple shapes are structural. A host
does not register a separate executable adapter for every `[Product]` or
`Target?` specialization. Custom `ExpressibleByArrayLiteral` witnesses can also
be registered; the automatic variadic trampoline supports up to 32 elements,
while an explicit array-backed adapter may be unbounded.

Rendered numeric arrays keep their element type with one outer cast, rather
than repeating a redundant cast on each literal:

```swift
[71, 73, 70, 56, 57, 97] as [Swift.UInt8]
```

This compact form applies when the explicit array element type matches the
linked built-in numeric values. The outer type remains important for overload
selection and empty arrays. Standalone values and erased or uncertain element
contexts retain the casts they need; nonfinite floating-point values keep
their specialized representations.

## Fallback is part of the design

ConstExpr does not contain Swift's constraint solver and does not interpret
arbitrary function bodies. It declines evaluation when correctness depends on
information it cannot prove, including:

- an unknown or ambiguous overload;
- an incomplete availability context;
- unsupported mutation, control flow, effects, or captures;
- a source declaration that shadows a registered declaration;
- a deprecated declaration whose compiler diagnostic must be preserved;
- a node, recursion, or automatic array-literal limit;
- an unknown active top-level statement in certifying mode.

Best-effort rewriting retains such source. Inline `#evaluate` retains its
original expression. A terminal host receives `ConstExprEvaluationFallback` and
can use the normal compiler path.

## Safety

`@ConstExpr` is a trust declaration. Registered code executes in the host
process and must be deterministic, terminating, nonmutating, and safe during a
build. ConstExpr does not sandbox callbacks and cannot prevent an annotation from
trapping, exiting, hanging, reading files, using the network, or mutating global
state.

Input source can choose any declaration exposed by its registry. Treat the
registry and input as trusted build inputs. See
[Safety and limitations](Documentation/Safety.md) for the complete trust model.

## How it works

At a high level:

1. `@ConstExpr` and `@ConstExprMembers` emit type-safe registration providers.
2. `#constExprRegistry` combines selected peers into an immutable registry.
3. The registry lazily compiles indexes for declarations, owners, structural
   types, literal adapters, and array-literal adapters.
4. `ConstExprRunner` parses and folds Swift operator sequences, tracks immutable
   lexical values, resolves registered calls using labels, types, defaults,
   availability, and overload preference, then invokes the linked adapters.
5. `ConstExprValue` carries renderable scalars and collections or opaque linked
   values used by later registered operations.
6. The runner either materializes rewritten Swift or extracts a named terminal
   value. Unknown and ambiguous cases preserve source or produce fallback.

The full design—including structural type resolution, lexical scopes, overload
ranking, availability, operator handling, instrumentation, and the trust
boundary—is documented in [Architecture](Documentation/Architecture.md).

## Examples and tools

- [`Sources/ConstExprExampleDefinitions`](Sources/ConstExprExampleDefinitions/Definitions.swift)
  shows functions, overloads, defaults, throwing calls, properties, enum cases,
  classes, subscripts, and opaque chains.
- [`Sources/ConstExprExampleRegistry`](Sources/ConstExprExampleRegistry/Registry.swift)
  aggregates that API surface.
- [`Examples`](Examples/README.md) demonstrates PacketKit's library-owned
  compiler macro and a separate consumer that imports only PacketKit.
- [`Documentation/PackageManifests.md`](Documentation/PackageManifests.md)
  discusses declarative manifest evaluation and host integration.
- [`Scripts/PackageIndex`](Scripts/PackageIndex/README.md) contains the resumable
  corpus harness.
- [`Scripts/Performance`](Scripts/Performance/README.md) contains the release
  profiling workflow.

Run the registry-specific example rewriter with:

```sh
swift run swift-constexpr-example Input.swift
swift run swift-constexpr-example --output Rewritten.swift Input.swift
cat Input.swift | swift run swift-constexpr-example -
```

Run the root suite and both PacketKit package suites with strict warnings and
dependency imports using:

```sh
swift test -Xswiftc -warnings-as-errors \
  --explicit-target-dependency-import-check error
swift test --package-path Examples/LibraryAuthor -Xswiftc -warnings-as-errors \
  --explicit-target-dependency-import-check error
swift test --package-path Examples/Consumer -Xswiftc -warnings-as-errors \
  --explicit-target-dependency-import-check error
```

The suites cover partial builder semantics, typed numeric-array rendering,
generated registries compiled in the same and separate modules, safe file
regeneration, and the complete GIF expansion and decoding. Also run the
[registry generation command](#generate-a-registry-from-an-annotated-target)
with `--check` to catch a stale checked-in registry.
