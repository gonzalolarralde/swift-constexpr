# Package manifest evaluation

ConstExpr can evaluate a useful declarative subset of `Package.swift`, but it
does not link or modify SwiftPM's real `PackageDescription` runtime. The example
uses a side-effect-free facade with the same source names and signatures for the
operations it supports. That facade is the rewrite-time half of a deliberate
double implementation: SwiftPM still compiles the rewritten manifest against its
real module.

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

## Literal values

Registered scalar literal conformers are also expected-type driven. For a custom
string, integer, floating-point, or Boolean literal target, ConstExpr verifies:

1. the linked target type actually has the matching `ExpressibleBy…Literal`
   conformance;
2. the conformance's associated literal type;
3. one nonthrowing registered initializer with the protocol label and that exact
   parameter type.

This keeps literal evaluation inside the explicit registry trust boundary.
Merely declaring a similarly named initializer is not enough. The conformance and
initializer must be visible in the annotated primary declaration; an unrelated
extension is not discovered by the attached macro.

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

## The bounded facade

The facade under `Examples/LibraryAuthor/Sources/PackageDescriptionModel` mirrors
only the signatures used by the consumer fixture. It intentionally does not copy
SwiftPM implementation bodies, historical overload sets, availability rules, or
manifest-process exit behavior. All supported factories, nested types,
conformances, and literal initializers are in primary declarations so the macro
can see them.

This is an API-era-specific adapter, not automatic support for every manifest.
Adding another PackageDescription operation means adding its safe facade
implementation and registry coverage. Current examples omit build settings,
resources, providers, registry dependencies, version ranges, plugins, language
modes, and most trait APIs. Environment reads, mutable construction, arbitrary
control flow, and closure-heavy manifests remain subject to the evaluator's
ordinary conservative boundaries.

## Why the consumer uses `build.sh`

A build-tool plugin cannot rewrite its own package manifest. SwiftPM must select
and evaluate root manifests before it has a resolved module graph or a build plan;
build-tool plugins run later and receive the package directory as read-only input.
A plugin also cannot dynamically relink its executable with registry products
discovered from an arbitrary dependency graph.

The example therefore uses an external bootstrap step:

1. `LibraryAuthor` exports its normal library and separate host-side registry
   provider products.
2. `Consumer/build.sh` generates a small driver package linked to ConstExpr and
   those providers.
3. It copies the consumer into a temporary sibling directory. The sibling layout
   preserves relative package dependencies such as `../LibraryAuthor`.
4. The driver rewrites `Package.swift`, `Sources/**/*.swift`, and
   `Tests/**/*.swift` into that stage.
5. The script runs `swift package dump-package` against the rewritten stage,
   builds it with a separate scratch path, and optionally runs its executable.

The checked-in consumer remains a valid ordinary Swift package and is never
modified. Its manifest imports only `PackageDescription`; a manifest cannot import
an arbitrary dependency module because evaluating the manifest is what discovers
that dependency. Provider-only manifest calls would therefore be a bootstrap-only
mode and must be completely removed by rewriting before stock SwiftPM could load
the result.

Run the complete author/consumer demonstration with:

```sh
cd Examples/Consumer
./build.sh --run
```

Use `./verify.sh` to additionally compare the rewritten manifest, rewritten
consumer source, and runtime output with the checked-in golden files.

Use `--keep-stage` to inspect the validated rewritten package. See
`Examples/README.md` for the file-by-file walkthrough.
