@_exported public import PacketKitModel

///// PacketKit's binary encoders, shared with its compiler plugin.
//public typealias Packet = PacketKitModel.Packet
//public typealias PacketBuilder = PacketKitModel.PacketBuilder
//public typealias GIF = PacketKitModel.GIF

/// Concatenates typed fields into bytes, folding known fields at compile time
/// and retaining dynamic fields as ordinary Swift computation.
@freestanding(expression)
public macro packetBytes(@PacketBuilder _ body: () -> [UInt8]) -> [UInt8] =
    #externalMacro(module: "PacketKitMacros", type: "PacketBytesMacro")

/// Requires every byte to be computed at compile time; unresolved input is an error.
@freestanding(expression)
public macro packetConstBytes(@PacketBuilder _ body: () -> [UInt8]) -> [UInt8] =
    #externalMacro(module: "PacketKitMacros", type: "PacketConstBytesMacro")
