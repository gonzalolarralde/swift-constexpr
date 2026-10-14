@_exported public import PacketKitModel

///// PacketKit's binary encoders, shared with its compiler plugin.
//public typealias Packet = PacketKitModel.Packet
//public typealias PacketBuilder = PacketKitModel.PacketBuilder
//public typealias GIF = PacketKitModel.GIF

/// Concatenates typed fields into bytes, folding known fields at compile time
/// and retaining dynamic fields as ordinary Swift computation.
/// Set `requireConstant` to true to reject any runtime fallback.
@freestanding(expression)
public macro packetBytes(requireConstant: Bool = false, @PacketBuilder _ body: () -> [UInt8]) -> [UInt8] =
    #externalMacro(module: "PacketKitMacros", type: "PacketBytesMacro")
