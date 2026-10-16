internal import ConstExpr

/// Small, explicit binary encoders. Multi-byte fields require a byte order.
@ConstExpr(registrationAccess: .package)
public enum Packet {
    @ConstExpr(registrationAccess: .package)
    public enum ByteOrder: Sendable {
        case littleEndian
        case bigEndian
    }

    public static func UInt8(_ value: Swift.UInt8) -> [Swift.UInt8] { [value] }

    public static func UInt16(_ value: Swift.UInt16, order: ByteOrder) -> [Swift.UInt8] {
        integer(Swift.UInt64(value), count: 2, order: order)
    }

    public static func UInt32(_ value: Swift.UInt32, order: ByteOrder) -> [Swift.UInt8] {
        integer(Swift.UInt64(value), count: 4, order: order)
    }

    public static func UInt64(_ value: Swift.UInt64, order: ByteOrder) -> [Swift.UInt8] {
        integer(value, count: 8, order: order)
    }

    public static func Bytes(_ values: [Swift.UInt8]) -> [Swift.UInt8] { values }

    public static func UTF8(_ value: String) -> [Swift.UInt8] { Array(value.utf8) }

    private static func integer(_ value: Swift.UInt64, count: Int, order: ByteOrder) -> [Swift.UInt8] {
        let bytes = (0..<count).map { Swift.UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
        return order == .littleEndian ? bytes : Array(bytes.reversed())
    }
}

public extension Packet {
    /// Ordinary Swift implementation used when a macro cannot fold its body.
    static func encode(@PacketBuilder _ body: () -> [Swift.UInt8]) -> [Swift.UInt8] { body() }
}
