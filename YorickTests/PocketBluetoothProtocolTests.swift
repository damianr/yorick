import XCTest

final class PocketBluetoothProtocolTests: XCTestCase {
    private func frame(session: UInt32 = 1, offset: UInt32 = 0) -> Data {
        var b: [UInt8] = [1,0xA1,3,0,0,0,0,0,0,0,0,0,0,0,0,0,0xE8,3,0,0,0x10]
        for i in 0..<4 { b[4+i] = UInt8(truncatingIfNeeded: session >> (8*i)); b[12+i] = UInt8(truncatingIfNeeded: offset >> (8*i)) }
        return Data(b)
    }
    func testKnownIMANibbleOrderAndPredictor() {
        XCTAssertEqual(PocketBluetoothProtocol.Frame(frame())?.samples, [1000,1000,1001])
    }
    func testMalformedFramesAreRejected() {
        let valid = frame()
        for length in 0..<valid.count { XCTAssertNil(PocketBluetoothProtocol.Frame(valid.prefix(length))) }
        var invalid = valid; invalid[18] = 89; XCTAssertNil(PocketBluetoothProtocol.Frame(invalid))
        invalid = valid; invalid[2] = 161; XCTAssertNil(PocketBluetoothProtocol.Frame(invalid))
        invalid = valid; invalid[0] = 2; XCTAssertNil(PocketBluetoothProtocol.Frame(invalid))
    }
    func testDuplicateAndOldSessionCannotAppendAudio() {
        var a = PocketBluetoothProtocol.Assembler(session: 1)
        XCTAssertEqual(a.accept(PocketBluetoothProtocol.Frame(frame())!)?.count, 3)
        XCTAssertNil(a.accept(PocketBluetoothProtocol.Frame(frame())!))
        XCTAssertNil(a.accept(PocketBluetoothProtocol.Frame(frame(session: 2, offset: 3))!))
        XCTAssertEqual(a.expectedOffset, 3)
    }
    func testGapsPreserveTimeAndAreCounted() {
        var a = PocketBluetoothProtocol.Assembler(session: 1)
        _ = a.accept(PocketBluetoothProtocol.Frame(frame())!)
        XCTAssertEqual(a.accept(PocketBluetoothProtocol.Frame(frame(offset: 5))!), [0,0,1000,1000,1001])
        XCTAssertEqual(a.missingSamples, 2)
        XCTAssertNil(a.accept(PocketBluetoothProtocol.Frame(frame(offset: 20000))!))
    }
    func testControlAcknowledgmentPreservesEventIdentity() {
        var raw = [UInt8](repeating: 0,count:20); raw[0] = 1; raw[1] = 3; raw[4] = 7; raw[8] = 9
        let e = PocketBluetoothProtocol.Event(Data(raw))!
        let ack = Array(e.acknowledgment(accepted: true))
        XCTAssertEqual(Array(ack[0...3]),[1,0x80,3,1]); XCTAssertEqual(ack[4],7); XCTAssertEqual(ack[8],9)
        XCTAssertNil(PocketBluetoothProtocol.Event(Data(raw.dropLast())))
    }
}
