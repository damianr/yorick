import Foundation

/// Wire protocol shared with firmware/pocket-ble-microphone/codec.h.
/// All multibyte fields are little endian. Every audio frame has its own IMA state.
enum PocketBluetoothProtocol {
    static let deviceUID = "yorick-pocket-ble"
    static let deviceName = "Yorick Pocket Bluetooth"
    static let service = "61C57A10-4CC3-4B68-ACD7-14C4A67E1200"
    static let audio = "61C57A10-4CC3-4B68-ACD7-14C4A67E1201"
    static let events = "61C57A10-4CC3-4B68-ACD7-14C4A67E1202"
    static let commands = "61C57A10-4CC3-4B68-ACD7-14C4A67E1203"
    static let steps = [7,8,9,10,11,12,13,14,16,17,19,21,23,25,28,31,34,37,41,45,50,55,60,66,73,80,88,97,107,118,130,143,157,173,190,209,230,253,279,307,337,371,408,449,494,544,598,658,724,796,876,963,1060,1166,1282,1411,1552,1707,1878,2066,2272,2499,2749,3024,3327,3660,4026,4428,4871,5358,5894,6484,7132,7845,8630,9493,10442,11487,12635,13899,15289,16818,18500,20350,22385,24623,27086,29794,32767]
    static let indices = [-1,-1,-1,-1,2,4,6,8]
    static func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | UInt32(b[i+1]) << 8 | UInt32(b[i+2]) << 16 | UInt32(b[i+3]) << 24
    }
    struct Event: Equatable {
        let type: UInt8
        let boot: UInt32
        let id: UInt32
        let session: UInt32
        let endSample: UInt32
        let raw: Data
        init?(_ data: Data) {
            let b = Array(data)
            guard b.count == 20, b[0] == 1, (1...5).contains(b[1]) else { return nil }
            type = b[1]; boot = u32(b, 4); id = u32(b, 8); session = u32(b, 12)
            endSample = u32(b, 16); raw = data
        }
        func acknowledgment(accepted: Bool) -> Data {
            var b = Array(raw); b[1] = 0x80; b[2] = type; b[3] = accepted ? 1 : 0
            return Data(b)
        }
    }
    struct Frame {
        let session: UInt32
        let sequence: UInt32
        let offset: UInt32
        let samples: [Int16]
        init?(_ data: Data) {
            let b = Array(data)
            guard b.count >= 20, b[0] == 1, b[1] == 0xA1, b[19] == 0 else { return nil }
            let count = Int(b[2]) | Int(b[3]) << 8
            guard (1...160).contains(count), b.count == 20 + count / 2, b[18] <= 88 else { return nil }
            session = u32(b, 4); sequence = u32(b, 8); offset = u32(b, 12)
            guard offset <= 4_800_000 else { return nil }
            var predictor = Int(Int16(bitPattern: UInt16(b[16]) | UInt16(b[17]) << 8))
            var index = Int(b[18]); var result = [Int16(predictor)]
            for i in 1..<count {
                let byte = b[20 + (i - 1) / 2]
                let n = Int((i & 1) == 1 ? byte & 15 : byte >> 4)
                let step = steps[index]
                var delta = step >> 3
                if n & 1 != 0 { delta += step >> 2 }
                if n & 2 != 0 { delta += step >> 1 }
                if n & 4 != 0 { delta += step }
                predictor = min(32767, max(-32768, predictor + (n & 8 != 0 ? -delta : delta)))
                index = min(88, max(0, index + indices[n & 7]))
                result.append(Int16(predictor))
            }
            samples = result
        }
        init(session: UInt32, sequence: UInt32, offset: UInt32, samples: [Int16]) {
            self.session = session; self.sequence = sequence; self.offset = offset; self.samples = samples
        }
    }
    struct Assembler {
        var session: UInt32
        private(set) var expectedOffset: UInt32 = 0
        private(set) var frames = 0
        private(set) var missingSamples = 0
        mutating func accept(_ frame: Frame) -> [Int16]? {
            guard frame.session == session, frame.offset >= expectedOffset else { return nil }
            let gap = Int(frame.offset - expectedOffset)
            guard gap <= 16_000 else { return nil }
            expectedOffset = frame.offset + UInt32(frame.samples.count)
            frames += 1; missingSamples += gap
            return [Int16](repeating: 0, count: gap) + frame.samples
        }
    }
    /// The skulls' Opus frame (format 0xA2): the same session, sequence and
    /// sample offset as an ADPCM frame, then one 20 ms Opus packet. `count`
    /// is under 320 only for the last, zero-padded frame of a session.
    struct OpusFrame {
        let session: UInt32
        let sequence: UInt32
        let offset: UInt32
        let count: Int
        let packet: Data
        init?(_ data: Data) {
            let b = Array(data)
            guard b.count > 16, b[0] == 1, b[1] == 0xA2 else { return nil }
            count = Int(b[2]) | Int(b[3]) << 8
            guard (1...OpusPacketDecoder.samplesPerPacket).contains(count) else { return nil }
            session = u32(b, 4); sequence = u32(b, 8); offset = u32(b, 12)
            guard offset <= 4_800_000 else { return nil }
            packet = data.subdata(in: data.startIndex + 16 ..< data.endIndex)
        }
        /// Decoded to exactly `count` samples, so offsets stay exact even
        /// when the codec's first packet comes out a little short.
        func frame(_ decoder: OpusPacketDecoder) -> Frame? {
            guard let pcm = decoder.decode(packet) else { return nil }
            var samples = Array(pcm.prefix(count))
            if samples.count < count { samples += [Int16](repeating: 0, count: count - samples.count) }
            return Frame(session: session, sequence: sequence, offset: offset, samples: samples)
        }
    }
    static func command(_ operation: UInt8) -> Data {
        var b = [UInt8](repeating: 0, count: 20); b[0] = 1; b[1] = operation
        return Data(b)
    }
}
