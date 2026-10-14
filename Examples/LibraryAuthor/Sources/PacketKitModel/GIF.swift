internal import ConstExpr

/// A deliberately tiny two-color GIF raster encoder for the example.
/// Each 16-bit row becomes two rows of 32 pixels (nearest-neighbor doubling).
/// The caller writes the matching dimensions in the GIF image descriptor.
@ConstExpr(registrationAccess: .package)
public enum GIF {
    public static func imageData(rows: [UInt16]) -> [UInt8] {
        var compressed: [UInt8] = []
        var buffer: UInt16 = 0
        var bitCount = 0
        func emit(_ code: UInt16) {
            buffer |= code << bitCount
            bitCount += 3
            while bitCount >= 8 {
                compressed.append(UInt8(truncatingIfNeeded: buffer))
                buffer >>= 8
                bitCount -= 8
            }
        }
        for row in rows {
            for _ in 0..<2 {
                for column in (0..<16).reversed() {
                    let pixel = (row >> column) & 1
                    for _ in 0..<2 {
                        // GIF permits a clear code anywhere. Clearing before
                        // each literal keeps codes at 3 bits: simple, not optimal
                        // compression. Minimum code size 2 => clear 4, end 5.
                        emit(4)
                        emit(pixel)
                    }
                }
            }
        }
        if rows.isEmpty { emit(4) }
        emit(5)
        if bitCount > 0 { compressed.append(UInt8(truncatingIfNeeded: buffer)) }

        var result: [UInt8] = [2] // LZW minimum code size
        for start in stride(from: 0, to: compressed.count, by: 255) {
            let end = min(start + 255, compressed.count)
            result.append(UInt8(end - start))
            result.append(contentsOf: compressed[start..<end])
        }
        result.append(0) // sub-block terminator
        return result
    }
}
