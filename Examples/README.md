# Separate-package consumer example

This example shows the two roles involved in a ConstExpr build without changing
either package's checked-in sources:

- `LibraryAuthor` publishes an ordinary `ManifestValues` product containing
  `@ConstExpr` declarations, including a custom array-literal collection whose
  elements are custom string-literal values. It separately publishes host-side
  registry-provider products. Applications do not need to depend on those
  provider products.
- `Consumer` has a stock-valid `Package.swift` and an ordinary executable target
  that imports `ManifestValues`. Its `build.sh` constructs the missing
  consumer-specific registry driver, rewrites a staged copy, validates the
  staged manifest, and asks SwiftPM to build that copy.

Run the complete flow with:

```sh
cd Examples/Consumer
./build.sh --run
```

Run the reproducible end-to-end check—including the stock manifest, staged
goldens, staged SwiftPM build, and executable output—with:

```sh
./verify.sh
```

The verifier always removes its temporary sibling stage, including when the
rewrite or build fails. Its ignored SwiftPM build caches remain available for
the next run.

The final line from the executable is:

```text
consumer=https://example.test/api/v1/users:443
```

Pass `--keep-stage` to inspect the rewritten sibling package:

```sh
./build.sh --keep-stage --run
```

The script prints the preserved path. Without that flag, its validated
temporary sibling is removed automatically. Driver and consumer build caches
remain below `Consumer/.build`; they are ignored by Git. Any extra arguments
after `--` are passed to the final `swift build` invocation.

## What the manifest demonstrates

The checked-in consumer manifest remains acceptable to plain SwiftPM. It uses:

- an immutable name assembled with operators;
- `let package: Package = .init(...)`;
- contextual factories such as `.library`, `.executableTarget`, and `.macOS`;
- a `Target.Dependency` created from a string literal;
- a `Set<Trait>` whose elements include both a custom string literal and a
  contextual `.default(enabledTraits:)` factory with a nested `Set<String>`;
- arrays containing opaque PackageDescription-shaped values;
- opaque values carried across bindings and queried through terminal
  properties.

`LibraryAuthor` contains a deliberately bounded, side-effect-free facade for
that PackageDescription subset. The rewriter executes the facade, while SwiftPM
compiles the retained syntax against its real `PackageDescription` module. APIs
that SwiftPM declares in extensions are repeated in the facade's primary type
bodies because `@ConstExpr` does not discover unrelated extensions.

The facade is an example fixture, not a promise to mirror the entire SwiftPM
manifest API. Unsupported valid syntax remains in the staged source for the
real manifest compiler.

## Why the external wrapper exists

SwiftPM evaluates `Package.swift` before it has a resolved package graph. A
build-tool plugin runs later, for a target in that already-resolved graph, and
can only contribute generated target sources and resources. It cannot replace
the manifest that created its own build plan.

There is a second linkage boundary: a plugin's executable dependencies are
declared statically, but the complete set of ConstExpr registry providers is a
consumer decision. `build.sh` bridges both boundaries by generating a tiny
driver package that depends on ConstExpr and the provider products, then using a
sibling package root so relative dependencies such as `../LibraryAuthor` retain
their meaning. The driver does not depend on `Consumer`, so bootstrap manifest
evaluation cannot recurse.

Provider discovery is intentionally explicit in this prototype. Adding another
annotated library means adding its registry-provider product to
`DriverTemplate/Package.swift` and appending that exported registry in the
driver's `main.swift`. The generated driver is the consumer-specific point
where otherwise independent provider modules are combined.

Golden output for inspection lives in `Consumer/Expected`.
