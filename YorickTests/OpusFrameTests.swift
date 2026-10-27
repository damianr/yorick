import XCTest

/// Skull firmware encodes with libopus (16 kHz, 20 ms SILK, 20 kbps CBR); these
/// packets came from the same libopus settings, encoding a 300 Hz sweep.
final class OpusFrameTests: XCTestCase {
    static let packets = ["4b01822fd8c3549a45bdb7150e096b5258a3f3f84b0dae41334891984b98d0890fabaaec1402cf2452ccebdd8c2dd3f11476", "48ade400d2a88e9fa7f11c03eb645c8c2493cf7226669589b1a304e700767ee1304005d4f1ff0b9777330e54c516444aec20", "4b41039bf6a05f2a6a41dc9ad8f56f670e1597915f3c37efd6f35b0e5441943a594a5e875d818fa462f9f5bee6f780000000", "4b41059c1b525875d6e9a2861db2c9eb37666ea20007f95597d6e602985d14bd0441369ec20601214461df19da0000000000", "4b41009c410031e291daaa34d559f7b3fbffc4c516bcaba2c6005ad3c8a582757608fb920c5efb5245e5b1b2e6fe7d39176c"].map { hex in
        Data(stride(from: 0, to: hex.count, by: 2).map { i in
            UInt8(hex[hex.index(hex.startIndex, offsetBy: i)..<hex.index(hex.startIndex, offsetBy: i + 2)], radix: 16)! })
    }

    private func wire(_ packet: Data, count: Int = 320, session: UInt32 = 7, sequence: UInt32, offset: UInt32) -> Data {
        var b: [UInt8] = [1, 0xA2, UInt8(count & 255), UInt8(count >> 8)]
        for v in [session, sequence, offset] { b += [UInt8(v & 255), UInt8(v >> 8 & 255), UInt8(v >> 16 & 255), UInt8(v >> 24)] }
        return Data(b) + packet
    }

    func testOpusFramesDecodeToExactSampleCounts() throws {
        let decoder = try XCTUnwrap(OpusPacketDecoder())
        var assembler = PocketBluetoothProtocol.Assembler(session: 7)
        var total = 0, peak = 0
        for (i, packet) in Self.packets.enumerated() {
            let opus = try XCTUnwrap(PocketBluetoothProtocol.OpusFrame(wire(packet, sequence: UInt32(i), offset: UInt32(i * 320))))
            let frame = try XCTUnwrap(opus.frame(decoder))
            XCTAssertEqual(frame.samples.count, 320)
            let samples = try XCTUnwrap(assembler.accept(frame))
            total += samples.count; peak = max(peak, samples.map { abs(Int($0)) }.max() ?? 0)
        }
        XCTAssertEqual(total, 1600)
        XCTAssertGreaterThan(peak, 2000, "decoded audio should carry the sweep, not silence")
    }

    func testShortFinalFrameKeepsItsCount() throws {
        let decoder = try XCTUnwrap(OpusPacketDecoder())
        let opus = try XCTUnwrap(PocketBluetoothProtocol.OpusFrame(wire(Self.packets[0], count: 123, sequence: 0, offset: 0)))
        XCTAssertEqual(try XCTUnwrap(opus.frame(decoder)).samples.count, 123)
    }

    func testADPCMFramesAreNotOpus() {
        XCTAssertNil(PocketBluetoothProtocol.OpusFrame(Data([1, 0xA1] + [UInt8](repeating: 0, count: 98))))
    }
}
