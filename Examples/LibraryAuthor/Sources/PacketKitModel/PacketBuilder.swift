internal import ConstExpr

@resultBuilder
public enum PacketBuilder {}

// Register the ordinary methods, not the result-builder attribute itself.
@ConstExprMembers(registrationAccess: .package)
public extension PacketBuilder {
    static func buildExpression(_ bytes: [UInt8]) -> [UInt8] { bytes }
    static func buildPartialBlock(first: [UInt8]) -> [UInt8] { first }
    static func buildPartialBlock(accumulated: [UInt8], next: [UInt8]) -> [UInt8] { accumulated + next }
    static func buildFinalResult(_ bytes: [UInt8]) -> [UInt8] { bytes }
    static func buildBlock() -> [UInt8] { [] }
}
