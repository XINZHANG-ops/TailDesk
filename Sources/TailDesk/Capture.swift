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
    private var isStopped = true
    private var isSwitching = false
    private var pendingDisplayID: UInt32?
    private(set) var displayID: UInt32?
    private(set) var displayList: RemoteDisplayList?

    func start() async throws {
        guard !isSwitching else { return }
        isStopped = false
        isSwitching = true
        defer { isSwitching = false }
        try await startCapture()
        try await switchToPendingDisplay()
    }

    func selectDisplay(_ displayID: UInt32) async throws {
        guard !isStopped else { return }
        pendingDisplayID = displayID
        guard !isSwitching else { return }
        isSwitching = true
        defer {
            isSwitching = false
            pendingDisplayID = nil
        }
        try await switchToPendingDisplay()
    }

    private func switchToPendingDisplay() async throws {
        while let targetDisplayID = pendingDisplayID {
            pendingDisplayID = nil
            guard !isStopped else { return }
            guard displayID != targetDisplayID else { continue }
            let oldStream = stream
            stream = nil
            encoder = nil
            try await oldStream?.stopCapture()
            guard !isStopped else { return }
            try await startCapture(preferredDisplayID: targetDisplayID)
        }
    }

    private func startCapture(preferredDisplayID: UInt32? = nil) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard !isStopped else { return }
        let mainDisplayID = CGMainDisplayID()
        let displays = content.displays.sorted { left, right in
            let leftIsMain = left.displayID == mainDisplayID
            let rightIsMain = right.displayID == mainDisplayID
            return leftIsMain == rightIsMain ? left.displayID < right.displayID : leftIsMain
        }
        guard let display = preferredDisplayID.flatMap({ id in displays.first { $0.displayID == id } })
                ?? displays.first else {
            throw CaptureError.noDisplay
        }
        displayID = display.displayID
        displayList = RemoteDisplayList(
            displays: displays.enumerated().map { index, item in
                RemoteDisplay(
                    id: item.displayID,
                    name: item.displayID == mainDisplayID ? "主屏幕" : "显示器 \(index + 1)",
                    width: item.width,
                    height: item.height,
                    isMain: item.displayID == mainDisplayID
                )
            },
            selectedDisplayID: display.displayID
        )

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
        do {
            try await stream.startCapture()
        } catch {
            self.stream = nil
            self.encoder = nil
            self.displayID = nil
            self.displayList = nil
            throw error
        }
        guard !isStopped else {
            self.stream = nil
            self.encoder = nil
            self.displayID = nil
            try? await stream.stopCapture()
            return
        }
        onStatus("Capturing \(width)×\(height) at up to 60 fps", false)
    }

    func stop() {
        isStopped = true
        let stream = self.stream
        self.stream = nil
        encoder = nil
        pendingDisplayID = nil
        displayID = nil
        displayList = nil
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
