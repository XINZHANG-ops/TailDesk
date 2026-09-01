import AVFAudio
import CoreMedia
import CoreVideo
import ScreenCaptureKit

final class ScreenCaptureSession: NSObject, SCStreamOutput, SCStreamDelegate {
    var onStatus: (String, Bool) -> Void = { _, _ in }
    var onVideoConfiguration: (Data) -> Void = { _ in }
    var onVideoFrame: (Data) -> Void = { _ in }
    var onAudioFrame: (Data) -> Void = { _ in }

    private let captureQueue = DispatchQueue(label: "TailDesk.ScreenCapture")
    private var stream: SCStream?
    private var encoder: H264Encoder?

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let mainDisplayID = CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == mainDisplayID }) ?? content.displays.first else {
            throw CaptureError.noDisplay
        }

        let scale = min(1, min(1920.0 / Double(display.width), 1080.0 / Double(display.height)))
        let width = max(2, Int(Double(display.width) * scale) / 2 * 2)
        let height = max(2, Int(Double(display.height) * scale) / 2 * 2)

        let encoder = try H264Encoder(width: width, height: height)
        encoder.onEncodedFrame = { [weak self] configuration, frame in
            if let configuration {
                self?.onVideoConfiguration(configuration)
            }
            self?.onVideoFrame(frame)
        }
        self.encoder = encoder

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.queueDepth = 3
        configuration.showsCursor = true
        configuration.capturesAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.excludesCurrentProcessAudio = true

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: captureQueue)
        self.stream = stream
        try await stream.startCapture()
        onStatus("Capturing \(width)×\(height) at up to 60 fps", false)
    }

    func stop() {
        let stream = self.stream
        self.stream = nil
        encoder = nil
        Task { try? await stream?.stopCapture() }
    }

    func requestKeyFrame() {
        encoder?.requestKeyFrame()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        switch type {
        case .screen:
            guard isFreshVideoFrame(sampleBuffer.presentationTimeStamp),
                  let pixelBuffer = sampleBuffer.imageBuffer else { return }
            encoder?.encode(pixelBuffer, presentationTimeStamp: sampleBuffer.presentationTimeStamp)
        case .audio:
            handleAudio(sampleBuffer)
        default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStatus("Capture stopped: \(error.localizedDescription)", true)
    }

    private func handleAudio(_ sampleBuffer: CMSampleBuffer) {
        try? sampleBuffer.withAudioBufferList { audioBufferList, _ in
            guard let description = sampleBuffer.formatDescription?.audioStreamBasicDescription,
                  let format = AVAudioFormat(
                    standardFormatWithSampleRate: description.mSampleRate,
                    channels: AVAudioChannelCount(description.mChannelsPerFrame)
                  ),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: audioBufferList.unsafePointer),
                  let data = RemoteAudioCodec.encode(buffer) else { return }
            onAudioFrame(data)
        }
    }
}

private func isFreshVideoFrame(_ timestamp: CMTime, now: CMTime = CMClockGetTime(CMClockGetHostTimeClock())) -> Bool {
    guard timestamp.isNumeric, now.isNumeric else { return true }
    // ponytail: fixed 100 ms ceiling; make it adaptive only if WAN telemetry warrants it.
    return CMTimeGetSeconds(CMTimeSubtract(now, timestamp)) < 0.1
}

enum CaptureSelfCheck {
    static func run() {
        let now = CMTime(seconds: 10, preferredTimescale: 600)
        precondition(isFreshVideoFrame(CMTime(seconds: 9.95, preferredTimescale: 600), now: now))
        precondition(!isFreshVideoFrame(CMTime(seconds: 9.8, preferredTimescale: 600), now: now))
        precondition(isFreshVideoFrame(.invalid, now: now))
    }
}

enum CaptureError: LocalizedError {
    case noDisplay

    var errorDescription: String? { "No display is available to capture" }
}
