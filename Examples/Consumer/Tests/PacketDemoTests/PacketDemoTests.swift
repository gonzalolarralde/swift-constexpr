import Foundation
import ImageIO
import CoreGraphics
@testable import PacketDemo
import PacketKit
import Testing

@Test func allFieldWidthsAndByteOrders() {
    let bytes = #packetConstBytes {
        Packet.UInt8(0xFF)
        Packet.UInt16(0x1234, order: .littleEndian)
        Packet.UInt16(0x1234, order: .bigEndian)
        Packet.UInt32(0x12345678, order: .littleEndian)
        Packet.UInt32(0x12345678, order: .bigEndian)
        Packet.UInt64(0x0123456789ABCDEF, order: .littleEndian)
        Packet.UInt64(0x0123456789ABCDEF, order: .bigEndian)
        Packet.UTF8("Hi!")
        let payload: [UInt8] = [0, 255]
        Packet.Bytes(payload)
    }
    #expect(bytes == [
        255, 0x34, 0x12, 0x12, 0x34,
        0x78, 0x56, 0x34, 0x12, 0x12, 0x34, 0x56, 0x78,
        0xEF, 0xCD, 0xAB, 0x89, 0x67, 0x45, 0x23, 0x01,
        0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF,
        72, 105, 33, 0, 255,
    ])
}

@Test func emptyBuilder() {
    let bytes = #packetConstBytes {}
    #expect(bytes.isEmpty)
}

@Test func maximumUnsignedValuesAreNotNarrowedToSignedIntegers() {
    let bytes = #packetConstBytes {
        Packet.UInt8(0xFF)
        Packet.UInt16(0xFFFF, order: .littleEndian)
        Packet.UInt32(0xFFFFFFFF, order: .littleEndian)
        Packet.UInt64(0xFFFFFFFFFFFFFFFF, order: .littleEndian)
    }
    #expect(bytes == Array(repeating: 255, count: 15))
}

@Test(arguments: [UInt8(0), 2, 255])
func runtimeCaptureUsesTheSameBuilder(opcode: UInt8) {
    let bytes = #packetBytes {
        Packet.UInt8(opcode)
        Packet.Bytes([3, 4])
    }
    #expect(bytes == Packet.encode {
        Packet.UInt8(opcode)
        Packet.Bytes([3, 4])
    })
}

@Test func consumerHelperFallsBackAndRunsOnce() {
    var calls = 0
    func makeBytes() -> [UInt8] { calls += 1; return [9, 8] }
    let bytes = #packetBytes {
        Packet.UInt8(7)
        makeBytes()
    }
    #expect(bytes == [7, 9, 8])
    #expect(calls == 1)
}

@Test func animationDecodesWithTwoDifferentLoopingFrames() throws {
    let source = try #require(CGImageSourceCreateWithData(Data(animatedGIF) as CFData, nil))
    #expect(CGImageSourceGetCount(source) == 2)
    let properties = try #require(CGImageSourceCopyProperties(source, nil) as? [String: Any])
    let gif = try #require(properties[kCGImagePropertyGIFDictionary as String] as? [String: Any])
    #expect((gif[kCGImagePropertyGIFLoopCount as String] as? Int) == 0)

    var frames: [[UInt8]] = []
    for index in 0..<2 {
        let frame = try #require(CGImageSourceCreateImageAtIndex(source, index, nil))
        #expect(frame.width == 32)
        #expect(frame.height == 32)
        let info = try #require(CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any])
        let metadata = try #require(info[kCGImagePropertyGIFDictionary as String] as? [String: Any])
        let delay = try #require(metadata[kCGImagePropertyGIFUnclampedDelayTime as String] as? Double)
        #expect(abs(delay - (index == 0 ? 0.8 : 0.2)) < 0.001)
        var pixels = [UInt8](repeating: 0, count: 32 * 32 * 4)
        try pixels.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(
                data: buffer.baseAddress, width: 32, height: 32,
                bitsPerComponent: 8, bytesPerRow: 32 * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(frame, in: CGRect(x: 0, y: 0, width: 32, height: 32))
        }
        let colors = stride(from: 0, to: pixels.count, by: 4).map {
            Array(pixels[$0..<$0 + 4])
        }
        #expect(colors.allSatisfy { $0 == [20, 27, 45, 255] || $0 == [105, 240, 174, 255] })
        #expect(colors.contains([105, 240, 174, 255]))
        frames.append(pixels)
    }
    #expect(frames[0] != frames[1])
    let changedPixels = stride(from: 0, to: frames[0].count, by: 4).filter {
        frames[0][$0] != frames[1][$0]
    }.count
    #expect(changedPixels == 12) // exactly three doubled source pixels wink
}
