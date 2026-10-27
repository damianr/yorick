import AudioToolbox
import Foundation

/// Decodes the skulls' Opus packets (16 kHz mono, 20 ms SILK wideband, from
/// libopus on the skull) with macOS's own Opus codec: one packet in, up to
/// 320 samples out. Keeps state between packets, as Opus expects.
final class OpusPacketDecoder {
    static let samplesPerPacket = 320
    private var converter: AudioConverterRef?
    // Read by the converter's input callback during decode().
    fileprivate var packet: UnsafeMutableRawBufferPointer?
    fileprivate let description = UnsafeMutablePointer<AudioStreamPacketDescription>.allocate(capacity: 1)
    fileprivate var consumed = false

    init?() {
        var input = AudioStreamBasicDescription(mSampleRate: 16000, mFormatID: kAudioFormatOpus, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: UInt32(Self.samplesPerPacket), mBytesPerFrame: 0, mChannelsPerFrame: 1,
            mBitsPerChannel: 0, mReserved: 0)
        var output = AudioStreamBasicDescription(mSampleRate: 16000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked, mBytesPerPacket: 2,
            mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        guard AudioConverterNew(&input, &output, &converter) == noErr, converter != nil else {
            description.deallocate(); return nil
        }
    }
    deinit {
        if let converter { AudioConverterDispose(converter) }
        description.deallocate()
    }

    /// Forget earlier packets: a new listening session starts clean.
    func reset() { if let converter { AudioConverterReset(converter) } }

    func decode(_ data: Data) -> [Int16]? {
        guard let converter, !data.isEmpty, data.count <= 1275 else { return nil }
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: data.count, alignment: 1)
        defer { buffer.deallocate(); packet = nil }
        data.copyBytes(to: buffer); packet = buffer; consumed = false
        var samples = [Int16](repeating: 0, count: Self.samplesPerPacket)
        var frames = UInt32(Self.samplesPerPacket)
        let status = samples.withUnsafeMutableBytes { out -> OSStatus in
            var list = AudioBufferList(mNumberBuffers: 1,
                mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(out.count), mData: out.baseAddress))
            return AudioConverterFillComplexBuffer(converter, opusInput, Unmanaged.passUnretained(self).toOpaque(), &frames, &list, nil)
        }
        guard status == noErr || status == opusNoMoreInput, frames > 0 else { return nil }
        return Array(samples.prefix(Int(frames)))
    }
}

/// Ours, not AudioToolbox's: the input callback has handed over its one packet.
private let opusNoMoreInput: OSStatus = 0x6E6D6F72 // 'nmor'

private func opusInput(_ converter: AudioConverterRef, _ count: UnsafeMutablePointer<UInt32>, _ data: UnsafeMutablePointer<AudioBufferList>,
                       _ descriptions: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?,
                       _ user: UnsafeMutableRawPointer?) -> OSStatus {
    let decoder = Unmanaged<OpusPacketDecoder>.fromOpaque(user!).takeUnretainedValue()
    guard !decoder.consumed, let packet = decoder.packet else { count.pointee = 0; return opusNoMoreInput }
    decoder.consumed = true
    data.pointee.mNumberBuffers = 1
    data.pointee.mBuffers = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(packet.count), mData: packet.baseAddress)
    decoder.description.pointee = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(packet.count))
    descriptions?.pointee = decoder.description
    count.pointee = 1
    return noErr
}
