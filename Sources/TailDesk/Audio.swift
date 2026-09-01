import AVFAudio
import Foundation

enum RemoteAudioCodec {
    private static let version: UInt8 = 1
    private static let headerSize = 10
    private static let maximumFrames = 8_192

    static func encode(_ buffer: AVAudioPCMBuffer) -> Data? {
        let channels = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)
        let sampleRate = Int(buffer.format.sampleRate.rounded())
        guard (1...2).contains(channels), (8_000...192_000).contains(sampleRate),
              (1...maximumFrames).contains(frames), let samples = buffer.floatChannelData else { return nil }

        var data = Data([version])
        append(UInt32(sampleRate), to: &data)
        data.append(UInt8(channels))
        append(UInt32(frames), to: &data)
        for channel in 0..<channels {
            data.append(Data(bytes: samples[channel], count: frames * MemoryLayout<Float>.size))
        }
        return data
    }

    static func decode(_ data: Data) throws -> AVAudioPCMBuffer {
        guard data.count >= headerSize, data[0] == version else { throw RemoteAudioError.invalidFrame }
        let sampleRate = Int(readUInt32(data, at: 1))
        let channels = Int(data[5])
        let frames = Int(readUInt32(data, at: 6))
        guard (8_000...192_000).contains(sampleRate), (1...2).contains(channels),
              (1...maximumFrames).contains(frames),
              data.count == headerSize + channels * frames * MemoryLayout<Float>.size,
              let format = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: AVAudioChannelCount(channels)),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let samples = buffer.floatChannelData else { throw RemoteAudioError.invalidFrame }

        buffer.frameLength = AVAudioFrameCount(frames)
        let byteCount = frames * MemoryLayout<Float>.size
        for channel in 0..<channels {
            let start = headerSize + channel * byteCount
            data.copyBytes(
                to: UnsafeMutableRawBufferPointer(start: samples[channel], count: byteCount),
                from: start..<(start + byteCount)
            )
        }
        return buffer
    }

    private static func append(_ value: UInt32, to data: inout Data) {
        var value = value.bigEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        data[offset..<(offset + 4)].reduce(0) { ($0 << 8) | UInt32($1) }
    }
}

final class RemoteAudioPlayer {
    var onError: (Error) -> Void = { _ in }

    private let queue = DispatchQueue(label: "TailDesk.RemoteAudioPlayer")
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var format: AVAudioFormat?
    private var queuedBuffers = 0

    init() {
        engine.attach(player)
    }

    func enqueue(_ data: Data) {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                let buffer = try RemoteAudioCodec.decode(data)
                try configureIfNeeded(buffer.format)
                // ponytail: cap latency by dropping audio above ~170 ms; add an adaptive jitter buffer only if WAN tests need it.
                guard queuedBuffers < 8 else { return }
                queuedBuffers += 1
                player.scheduleBuffer(buffer) { [weak self] in
                    self?.queue.async { self?.queuedBuffers = max(0, (self?.queuedBuffers ?? 1) - 1) }
                }
                if !player.isPlaying { player.play() }
            } catch {
                onError(error)
            }
        }
    }

    func stop() {
        queue.sync {
            player.stop()
            engine.stop()
            queuedBuffers = 0
            format = nil
        }
    }

    private func configureIfNeeded(_ format: AVAudioFormat) throws {
        guard self.format?.sampleRate != format.sampleRate || self.format?.channelCount != format.channelCount else { return }
        player.stop()
        engine.stop()
        engine.disconnectNodeOutput(player)
#if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try session.setActive(true)
#endif
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.prepare()
        try engine.start()
        self.format = format
        queuedBuffers = 0
    }
}

enum RemoteAudioError: LocalizedError {
    case invalidFrame

    var errorDescription: String? { "Invalid remote audio frame" }
}

enum AudioSelfCheck {
    static func run() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let source = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4)!
        source.frameLength = 4
        source.floatChannelData![0][2] = 0.25
        source.floatChannelData![1][3] = -0.5
        let encoded = RemoteAudioCodec.encode(source)!
        let decoded = try! RemoteAudioCodec.decode(encoded)
        precondition(decoded.frameLength == 4 && decoded.format.channelCount == 2)
        precondition(decoded.floatChannelData![0][2] == 0.25)
        precondition(decoded.floatChannelData![1][3] == -0.5)
        precondition((try? RemoteAudioCodec.decode(Data(encoded.dropLast()))) == nil)
    }
}
