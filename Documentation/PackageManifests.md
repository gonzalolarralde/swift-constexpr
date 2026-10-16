# Package manifest evaluation

Manifest evaluation is a host-integration use case, separate from the
[library-owned compiler macro example](../Examples/README.md). The previous
staged PackageDescription-facade example has been replaced by PacketKit; the
consumer no longer rewrites its manifest or generates its own registry driver.

The alternative SwiftPM loader experiment conditionally annotates the real
PackageDescription implementation, resolves the global `let package` as a
linked value, calls a host-only canonical JSON SPI, and feeds that JSON to the
existing `ManifestJSONParser`. Successful evaluation does not compile or run
the manifest source as a program, but it does invoke trusted, already-compiled
registrations in the evaluator's process. Isolation is the host's responsibility.

The SwiftPM path is all-or-nothing. It configures active `#if` regions, requires
an explicit PackageDescription import and an admissible immutable top level, and
evaluates in certifying mode with the manifest tools-version availability
context. Any unknown name, ambiguity, unsupported effect/mutation, syntax issue,
adapter failure, or unresolved value silently invokes the normal executing loader
with the original bytes. An experimental developer flag can expose structured
fallback reasons, and crosscheck mode compares the canonical final manifests.

The design was checked against SwiftPM's
`Sources/Runtimes/PackageDescription` sources in a local SwiftPM checkout.
The practical minimum is larger than `Package.init`. Ordinary manifests depend
heavily on contextual leading-dot syntax:

```swift
let localSupport: Target.Dependency = "LocalSupport"

let package: Package = .init(
    name: "Garden",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Garden", targets: ["Garden"]),
    ],
    traits: [.default(enabledTraits: ["Metrics"]), "Metrics"],
    dependencies: [
        .package(path: "../Local"),
        .package(url: "https://example.test/log.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "Garden",
            dependencies: [
                localSupport,
                .product(name: "Logging", package: "log"),
            ]
        ),
    ]
)
```

The evaluator now resolves `.init`, contextual static methods such as
`.library`, `.package`, and `.target`, and contextual static values such as
`.v14`. It first resolves the expected nominal type, then requires the
registration owner to be that exact type. Labels, defaults, arguments, and result
conversions go through the normal overload resolver. More than one best overload
means no invocation: the original expression stays for the compiler.

## Real PackageDescription registration

The experiment conditionally annotates whole PackageDescription types with
`@ConstExpr(registrationAccess: .package)` and extensions with
`@ConstExprMembers(named:registrationAccess:)`. Each scope automatically
registers every eligible immediate declaration; unsupported members are omitted,
and `@ConstExprIgnored` excludes an otherwise eligible declaration whose body is
not safe for speculative execution. Direct annotations remain only for isolated
leaf declarations. The generated helpers stay beside their declarations, while
an explicit host provider contains no handwritten Product/Target/Dependency
decoding closures. Package's large literal-default initializer uses the macro's
linear adapter. Context values are the intentional exception: package directory,
environment, and Git information are injected per load rather than reading
PackageDescription's process-global command-line model.

Every generated entry records `_PackageDescription` introduced/obsoleted versions
and `_disfavoredOverload`. The runner receives the manifest tools version and
falls back when the active overload set cannot be proven. The initial loader
supports tools version 5.9 and newer; older API eras are measured separately and
remain executing-loader work until their complete overload sets are registered.

## Literal values

Registered scalar literal conformers are also expected-type driven. For a custom
string, integer, floating-point, or Boolean literal target, ConstExpr verifies:

1. the linked target type actually has the matching `ExpressibleBy…Literal`
   conformance;
2. the conformance's associated literal type;
3. one nonthrowing registered initializer with the protocol label and that exact
   parameter type.

This keeps literal evaluation inside the explicit registry trust boundary.
Merely declaring a similarly named initializer is not enough. A nominal
annotation can automatically pair only a conformance and witness visible in its
primary declaration. An extension-only witness can participate when that
initializer is explicitly annotated with `@ConstExpr`; unrelated, unannotated
extensions are not discovered.

Array literals recursively pass their element type to each expression. This
allows `[Target.Dependency]` to contain strings and contextual `.product(...)`
calls. `Array` and `Set` have unlimited standard adapters through the common
array-literal registration path, covering PackageDescription-style trait sets
with nested string-literal elements.

An annotated user-owned type can participate when its primary declaration
directly names `ExpressibleByArrayLiteral` and contains exactly one eligible
`init(arrayLiteral:)` witness. The macro-generated witness trampoline accepts up
to 32 elements; a larger literal stays unchanged with a diagnostic because
stable Swift cannot splat a runtime array into a variadic initializer. A facade
that needs an unlimited custom collection can provide an explicitly trusted
array-backed `ConstExprRegistration.arrayLiteral(..., build:)` adapter. Missing
context, an unknown child, multiple exact adapters, and extension-only
conformances or witnesses all preserve the original literal for the compiler.

## Why manifest evaluation needs host integration

A build-tool plugin cannot rewrite its own package manifest. SwiftPM must select
and evaluate root manifests before it has a resolved module graph or a build plan;
build-tool plugins run later and receive the package directory as read-only input.
A plugin also cannot dynamically relink its executable with registry products
discovered from an arbitrary dependency graph.

A manifest loader or external host must therefore supply the trusted registry
and control the evaluate-or-compile decision. A manifest cannot import an
arbitrary package dependency merely because it declares that dependency;
evaluating the manifest is what discovers the package graph.

Library-owned expression macros have a different lifecycle: their dependencies
are already resolved when ordinary target source is compiled. PacketKit can
ship its registry in its own compiler plugin and let consumers build normally.
See [Examples](../Examples/README.md) for that simpler author/consumer workflow.
