# PacketKit: an animated GIF, generated at compile time

This example builds a 1,625-byte, 32×32 animated GIF: a mint pixel face that
winks, then repeats forever. The entire file—including its palette, frame
timing, loop extension, and LZW image data—is generated during macro expansion.
The CLI only chooses an output path and writes the resulting constant bytes.

From the repository root, using Swift 6.3:

```sh
swift run --package-path Examples/Consumer PacketDemo /tmp/packet.gif
open /tmp/packet.gif
```

Expected output:

```text
Wrote 1625 bytes to /tmp/packet.gif
```

Omit the argument to write `packet.gif` in the current directory. An existing
file at the chosen path is replaced atomically. File-system errors are reported
by the CLI. The example's decoder tests use macOS ImageIO.

## The consumer's view

The application imports only `PacketKit` and depends on its single product:

```swift
// Consumer/Package.swift
dependencies: [
    .package(path: "../LibraryAuthor"),
],
targets: [
    .executableTarget(
        name: "PacketDemo",
        dependencies: [
            .product(name: "PacketKit", package: "LibraryAuthor"),
        ]
    ),
]
```

`LibraryAuthor` is the local package directory and therefore the dependency
identity. Its sole library product and public module are named `PacketKit`.
There is no consumer-side ConstExpr import, registry, or special build script.

The result-builder syntax combines integer fields, UTF-8 strings, and arrays:

```swift
import PacketKit

let bytes = #packetBytes(requireConstant: true) {
    let payload: [UInt8] = [16, 32]
    Packet.UInt64(0x0102030405060708, order: .bigEndian)
    Packet.UInt8(2)
    Packet.Bytes(payload)
}
// Expands to literal bytes: [1, 2, 3, 4, 5, 6, 7, 8, 2, 16, 32].
```

`Packet.UInt8`, `UInt16`, `UInt32`, and `UInt64` accept the corresponding Swift
integer types; multi-byte fields require an explicit byte order. `Packet.Bytes`
embeds a `[UInt8]` directly, and `Packet.UTF8` encodes a string. All produce
`[UInt8]` components, concatenated by `PacketBuilder`.

[Animation.swift](Consumer/Sources/PacketDemo/Animation.swift) contains the
complete GIF definition in one `#packetBytes(requireConstant: true)` body.
Each frame is drawn as sixteen binary integer rows, so the actual art remains
readable in source. `GIF.imageData(rows:)` doubles each source pixel and packs
the raster into GIF image-data sub-blocks. The first frame lasts 0.8 seconds;
the wink lasts 0.2 seconds.

[main.swift](Consumer/Sources/PacketDemo/main.swift) only writes the bytes:

```swift
let path = CommandLine.arguments.dropFirst().first ?? "packet.gif"
try Data(animatedGIF).write(to: URL(fileURLWithPath: path), options: .atomic)
```

### A build-time guarantee, not an optimizer hint

`requireConstant: true` reports a compiler error if evaluation is unresolved,
unsupported, or cannot produce Swift source. The GIF is therefore a literal
byte array even in a debug build; there is no runtime encoder fallback.
Keep constants inside the macro body or expose them through registered library
declarations. The macro cannot discover arbitrary outer consumer bindings.

When the flag is omitted (or false), runtime values are allowed:

```swift
func message(opcode: UInt8) -> [UInt8] {
    #packetBytes {
        Packet.UInt8(opcode)
        Packet.Bytes([3, 4])
    }
}
```

That expands to `Packet.encode { ... }`, preserving the entire body and using
the ordinary Swift result builder. An unregistered consumer helper can also
use this fallback. There is no partial compile-time/runtime mixture.

## The library author's view

The public surface is one product; the implementation uses three targets:

- `PacketKit`: the macro declaration and public aliases for the model types.
- `PacketKitModel`: the byte encoders, builder, and small GIF raster helper.
- `PacketKitMacros`: the registry and thin compiler plugin.

The shared model avoids a cycle: the public target depends on the macro
target, which cannot in turn depend on that public target. Neither internal
target is exposed as a separate product.

The library author uses `internal import ConstExpr` and
`@ConstExpr(registrationAccess: .package)` for its types. Builder methods live
in an extension annotated with `@ConstExprMembers(registrationAccess: .package)`.
The annotations generate package-scoped registration providers without adding
ConstExpr types to the public API.

[PacketBytesMacro.swift](LibraryAuthor/Sources/PacketKitMacros/PacketBytesMacro.swift)
registers the encoders, byte-order enum, GIF helper, and builder hooks, then
delegates the entire expansion algorithm:

```swift
ConstExprBuilderMacroSupport.expansion(
    of: macro,
    in: context,
    registry: registry,
    builderType: "PacketBuilder",
    runtimeFunction: "Packet.encode",
    requireConstantArgumentLabel: "requireConstant"
)
```

The helper supports synchronous, nonthrowing straight-line expressions and
immutable local bindings. Explicit `try` and `await` remain compiler work.
It invokes the registered `buildExpression`, both `buildPartialBlock` methods,
`buildFinalResult`, and (for an empty body) `buildBlock`. Expression evaluation
precedes partial-block accumulation, following
[SE-0348](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0348-buildpartialblock.md).
Unsupported syntax falls back as a whole, or errors in strict mode. This is
not a general result-builder type checker; the library supplies pure,
unambiguous builder hooks matching its runtime implementation. PacketBuilder
itself intentionally has no conditional or loop-building hooks.

The GIF helper's loops execute as native Swift in the compiler-plugin process,
through its registered function. ConstExpr does not interpret the encoder's
implementation or contain any GIF-specific logic. The image data uses a simple
literal-only LZW stream: a clear code before each pixel keeps codes at three
bits. This is deliberately readable, not optimal compression. The caller must
match the raster dimensions and two-color palette to the image descriptor.
See the [GIF89a specification](https://www.w3.org/Graphics/GIF/spec-gif89a.txt).

ConstExpr and SwiftSyntax remain transitive build dependencies. This example
hides their setup and API from the consumer; it does not promise their removal
from the dependency graph or a particular linked executable size.

## Verification

```sh
swift test --package-path Examples/LibraryAuthor -Xswiftc -warnings-as-errors \
  --explicit-target-dependency-import-check error
swift test --package-path Examples/Consumer -Xswiftc -warnings-as-errors \
  --explicit-target-dependency-import-check error
swift test -Xswiftc -warnings-as-errors \
  --explicit-target-dependency-import-check error
```

The author tests expand the **actual CLI animation source** and require exactly
one literal array, 1,625 bytes, and no surviving function or macro calls.
Consumer tests compile from a separate package and independently decode the
GIF with ImageIO, checking both frames, dimensions, palette, timing, infinite
looping, and the exact twelve changed output pixels. They also cover field
widths, both byte orders, empty builders, and runtime fallback. Root tests
cover the reusable helper, including strict-mode failures, opaque results,
unsupported syntax, and non-PacketKit builder semantics.
