import AVFAudio

/// Converts capture buffers to the canonical stream format: 16 kHz mono Float32.
/// Downmixing is done here (AVAudioConverter's multichannel downmix produced silence
/// in Whisper Verses); the converter only ever resamples mono to 16 kHz.
final class MonoResampler {
    enum ChannelMode { case firstChannel, sumAll }

    static let canonicalFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    private let channelMode: ChannelMode
    private var converter: AVAudioConverter?
    private var converterInputRate: Double = 0

    init(channelMode: ChannelMode) { self.channelMode = channelMode }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let src = buffer.floatChannelData, buffer.frameLength > 0 else { return nil }
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        let rate = buffer.format.sampleRate
        guard let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: AVAudioFrameCount(frames)),
              let dst = mono.floatChannelData?[0] else { return nil }
        mono.frameLength = AVAudioFrameCount(frames)
        if channelMode == .firstChannel || channels == 1 {
            dst.update(from: src[0], count: frames)
        } else {
            for i in 0..<frames {
                var sum: Float = 0
                for c in 0..<channels { sum += src[c][i] }
                dst[i] = max(-1, min(1, sum))
            }
        }
        if rate == Self.canonicalFormat.sampleRate { return mono }
        if converter == nil || converterInputRate != rate {
            converter = AVAudioConverter(from: monoFormat, to: Self.canonicalFormat)
            converterInputRate = rate
        }
        let capacity = AVAudioFrameCount(Double(frames) * Self.canonicalFormat.sampleRate / rate) + 1024
        guard let converter, let out = AVAudioPCMBuffer(pcmFormat: Self.canonicalFormat, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return mono
        }
        return error == nil && out.frameLength > 0 ? out : nil
    }

    static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += data[i] * data[i] }
        return (sum / Float(buffer.frameLength)).squareRoot()
    }

    static func samples(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let data = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
    }
}
