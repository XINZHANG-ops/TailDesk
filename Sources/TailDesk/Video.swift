import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

#if os(macOS)
private let compressionCallback: VTCompressionOutputCallback = { refcon, _, status, _, sampleBuffer in
    guard status == noErr, let refcon, let sampleBuffer else { return }
    Unmanaged<H264Encoder>.fromOpaque(refcon).takeUnretainedValue().handleEncoded(sampleBuffer)
}

final class H264Encoder {
    var onEncodedFrame: (Data?, Data) -> Void = { _, _ in }

    private var session: VTCompressionSession?
    private let forceKeyFrameLock = NSLock()
    private var shouldForceKeyFrame = true

    init(width: Int, height: Int) throws {
        let encoderSpecification: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true
        ]
        let imageAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferMetalCompatibilityKey: true
        ]
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: encoderSpecification as CFDictionary,
            imageBufferAttributes: imageAttributes as CFDictionary,
            compressedDataAllocator: nil,
            outputCallback: compressionCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &session
        )
        guard status == noErr, let session else { throw VideoError.encoder(status) }
        self.session = session

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: NSNumber(value: 1))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: 60))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: 24_000_000))
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    deinit {
        if let session {
            VTCompressionSessionInvalidate(session)
        }
    }

    func requestKeyFrame() {
        forceKeyFrameLock.lock()
        shouldForceKeyFrame = true
        forceKeyFrameLock.unlock()
    }

    func encode(_ pixelBuffer: CVPixelBuffer, presentationTimeStamp: CMTime) {
        guard let session else { return }
        forceKeyFrameLock.lock()
        let force = shouldForceKeyFrame
        shouldForceKeyFrame = false
        forceKeyFrameLock.unlock()

        let properties = force ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: presentationTimeStamp,
            duration: .invalid,
            frameProperties: properties,
            sourceFrameRefcon: nil,
            infoFlagsOut: nil
        )
    }

    fileprivate func handleEncoded(_ sampleBuffer: CMSampleBuffer) {
        guard let blockBuffer = sampleBuffer.dataBuffer else { return }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]]
        let isKeyFrame = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool != true

        let encodedLength = blockBuffer.dataLength
        var encoded = Data(count: encodedLength)
        let copyStatus = encoded.withUnsafeMutableBytes { bytes in
            CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: encodedLength, destination: bytes.baseAddress!)
        }
        guard copyStatus == noErr else { return }

        var configuration: Data?
        if isKeyFrame, let format = sampleBuffer.formatDescription {
            configuration = Self.configuration(from: format)
        }
        onEncodedFrame(configuration, encoded)
    }

    private static func configuration(from format: CMFormatDescription) -> Data? {
        var parameterSetCount = 0
        var nalHeaderLength: Int32 = 0
        var spsPointer: UnsafePointer<UInt8>?
        var spsSize = 0
        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format,
            parameterSetIndex: 0,
            parameterSetPointerOut: &spsPointer,
            parameterSetSizeOut: &spsSize,
            parameterSetCountOut: &parameterSetCount,
            nalUnitHeaderLengthOut: &nalHeaderLength
        ) == noErr, let spsPointer else { return nil }

        var ppsPointer: UnsafePointer<UInt8>?
        var ppsSize = 0
        guard parameterSetCount > 1,
              CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format,
                parameterSetIndex: 1,
                parameterSetPointerOut: &ppsPointer,
                parameterSetSizeOut: &ppsSize,
                parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: nil
              ) == noErr,
              let ppsPointer,
              spsSize <= Int(UInt16.max), ppsSize <= Int(UInt16.max) else { return nil }

        var data = Data()
        append(UInt16(spsSize), to: &data)
        data.append(spsPointer, count: spsSize)
        append(UInt16(ppsSize), to: &data)
        data.append(ppsPointer, count: ppsSize)
        return data
    }
}
#endif

final class H264Decoder {
    var onFrame: (CGImage) -> Void = { _ in }

    private let imageContext = CIContext(options: [.cacheIntermediates: false])
    private var formatDescription: CMVideoFormatDescription?
    private var session: VTDecompressionSession?

    deinit { invalidate() }

    func configure(_ data: Data) throws {
        let (sps, pps) = try parseConfiguration(data)
        invalidate()

        let format = try makeFormatDescription(sps: sps, pps: pps)
        let imageAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey: true
        ]
        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: format,
            decoderSpecification: nil,
            imageBufferAttributes: imageAttributes as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &session
        )
        guard status == noErr, let session else { throw VideoError.decoder(status) }
        formatDescription = format
        self.session = session
    }

    func decode(_ data: Data) {
        guard let session, let formatDescription else { return }
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: data.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: data.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        ) == noErr, let blockBuffer else { return }

        let copied = data.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: data.count)
        }
        guard copied == noErr else { return }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )
        var sampleSize = data.count
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer else { return }

        _ = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: [._EnableAsynchronousDecompression, ._1xRealTimePlayback],
            infoFlagsOut: nil,
            completionHandler: { [weak self] status, _, imageBuffer, _, _, _ in
                guard status == noErr, let imageBuffer else { return }
                self?.handleDecoded(imageBuffer)
            }
        )
    }

    fileprivate func handleDecoded(_ imageBuffer: CVImageBuffer) {
        let image = CIImage(cvImageBuffer: imageBuffer)
        guard let cgImage = imageContext.createCGImage(image, from: image.extent) else { return }
        onFrame(cgImage)
    }

    private func invalidate() {
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
        formatDescription = nil
    }

    private func parseConfiguration(_ data: Data) throws -> (Data, Data) {
        guard data.count >= 4 else { throw VideoError.invalidConfiguration }
        let spsLength = Int(data[0]) << 8 | Int(data[1])
        guard data.count >= 2 + spsLength + 2 else { throw VideoError.invalidConfiguration }
        let spsStart = 2
        let ppsLengthIndex = spsStart + spsLength
        let ppsLength = Int(data[ppsLengthIndex]) << 8 | Int(data[ppsLengthIndex + 1])
        let ppsStart = ppsLengthIndex + 2
        guard data.count == ppsStart + ppsLength else { throw VideoError.invalidConfiguration }
        return (Data(data[spsStart..<ppsLengthIndex]), Data(data[ppsStart..<data.count]))
    }

    private func makeFormatDescription(sps: Data, pps: Data) throws -> CMVideoFormatDescription {
        var description: CMFormatDescription?
        let status = sps.withUnsafeBytes { spsBytes in
            pps.withUnsafeBytes { ppsBytes in
                let pointers = [
                    spsBytes.bindMemory(to: UInt8.self).baseAddress!,
                    ppsBytes.bindMemory(to: UInt8.self).baseAddress!
                ]
                let sizes = [sps.count, pps.count]
                return pointers.withUnsafeBufferPointer { pointerBuffer in
                    sizes.withUnsafeBufferPointer { sizeBuffer in
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: pointerBuffer.baseAddress!,
                            parameterSetSizes: sizeBuffer.baseAddress!,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &description
                        )
                    }
                }
            }
        }
        guard status == noErr, let description else { throw VideoError.decoder(status) }
        return description
    }
}

enum VideoError: LocalizedError {
    case encoder(OSStatus)
    case decoder(OSStatus)
    case invalidConfiguration

    var errorDescription: String? {
        switch self {
        case .encoder(let status): "Unable to create H.264 encoder (\(status))"
        case .decoder(let status): "Unable to create H.264 decoder (\(status))"
        case .invalidConfiguration: "Invalid H.264 configuration"
        }
    }
}

#if os(macOS)
private func append(_ value: UInt16, to data: inout Data) {
    var bigEndian = value.bigEndian
    withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
}

enum VideoSelfCheck {
    static func run() {
        let width = 320
        let height = 180
        var pixelBuffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        precondition(CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes,
            &pixelBuffer
        ) == kCVReturnSuccess)
        guard let pixelBuffer else { preconditionFailure("Pixel buffer creation failed") }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) {
            memset(baseAddress, 0x7f, CVPixelBufferGetDataSize(pixelBuffer))
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

        let decoded = DispatchSemaphore(value: 0)
        let decoder = H264Decoder()
        decoder.onFrame = { image in
            precondition(image.width == width && image.height == height)
            decoded.signal()
        }
        let encoder = try! H264Encoder(width: width, height: height)
        encoder.onEncodedFrame = { configuration, frame in
            guard let configuration else { return }
            try! decoder.configure(configuration)
            decoder.decode(frame)
        }
        encoder.encode(pixelBuffer, presentationTimeStamp: .zero)
        precondition(decoded.wait(timeout: .now() + 5) == .success, "H.264 round-trip timed out")
    }
}
#endif
