import PacketKit

// This MUST become a byte-array literal, even in a debug build. Any unknown
// value, unsupported syntax, or encoding failure produces a compiler error.
let animatedGIF: [UInt8] = #packetConstBytes {
    let size: UInt16 = 32
    let palette: [UInt8] = [0x14, 0x1B, 0x2D, 0x69, 0xF0, 0xAE] // midnight / mint

    Packet.UTF8("GIF89a")
    Packet.UInt16(size, order: .littleEndian)
    Packet.UInt16(size, order: .littleEndian)
    Packet.UInt8(0xF0) // global palette, 8-bit color resolution, two colors
    Packet.UInt8(0) // background palette index
    Packet.UInt8(0) // square pixels
    Packet.Bytes(palette)

    // Netscape application extension: repeat forever (loop count zero).
    Packet.Bytes([0x21, 0xFF, 11])
    Packet.UTF8("NETSCAPE2.0")
    Packet.Bytes([3, 1])
    Packet.UInt16(0, order: .littleEndian)
    Packet.UInt8(0)

    // Frame 1: a smiling pixel face, held for 0.8 seconds.
    Packet.Bytes([0x21, 0xF9, 4, 4]) // graphics control, keep frame, opaque
    Packet.UInt16(80, order: .littleEndian) // hundredths of a second
    Packet.Bytes([0, 0]) // unused transparent index and terminator
    Packet.UInt8(0x2C) // image descriptor
    Packet.UInt16(0, order: .littleEndian) // left
    Packet.UInt16(0, order: .littleEndian) // top
    Packet.UInt16(size, order: .littleEndian)
    Packet.UInt16(size, order: .littleEndian)
    Packet.UInt8(0) // use global palette, not interlaced
    Packet.Bytes(GIF.imageData(rows: [
        0b0000000000000000,
        0b0000000000000000,
        0b0000011111100000,
        0b0001111111111000,
        0b0011111111111100,
        0b0011100110011100,
        0b0111100110011110,
        0b0111111111111110,
        0b0111111111111110,
        0b0111011111101110,
        0b0011100000011100,
        0b0011111111111100,
        0b0001111111111000,
        0b0000011111100000,
        0b0000000000000000,
        0b0000000000000000,
    ]))

    // Frame 2: a quick wink, held for 0.2 seconds.
    Packet.Bytes([0x21, 0xF9, 4, 4])
    Packet.UInt16(20, order: .littleEndian)
    Packet.Bytes([0, 0])
    Packet.UInt8(0x2C)
    Packet.UInt16(0, order: .littleEndian)
    Packet.UInt16(0, order: .littleEndian)
    Packet.UInt16(size, order: .littleEndian)
    Packet.UInt16(size, order: .littleEndian)
    Packet.UInt8(0)
    Packet.Bytes(GIF.imageData(rows: [
        0b0000000000000000,
        0b0000000000000000,
        0b0000011111100000,
        0b0001111111111000,
        0b0011111111111100,
        0b0011100111111100,
        0b0111100100011110,
        0b0111111111111110,
        0b0111111111111110,
        0b0111011111101110,
        0b0011100000011100,
        0b0011111111111100,
        0b0001111111111000,
        0b0000011111100000,
        0b0000000000000000,
        0b0000000000000000,
    ]))
    Packet.UInt8(0x3B) // GIF trailer
}
