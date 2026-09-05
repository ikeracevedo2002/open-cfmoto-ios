import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

enum H264VideoStreamError: LocalizedError {
    case compressionSession(OSStatus)
    case compressionProperty(CFString, OSStatus)
    case pixelBuffer
    case encode(OSStatus)

    var errorDescription: String? {
        switch self {
        case .compressionSession(let status):
            return "VideoToolbox session failed (\(status))"
        case .compressionProperty(let key, let status):
            return "VideoToolbox property \(key) failed (\(status))"
        case .pixelBuffer:
            return "Could not allocate an H.264 source frame"
        case .encode(let status):
            return "VideoToolbox encode failed (\(status))"
        }
    }
}

/// Produces an app-owned projection surface and exposes its encoded access
/// units in the same lock-step fashion used by EasyConn command 114.
final class H264VideoStream {
    typealias LogHandler = (String) -> Void

    private let encoderQueue = DispatchQueue(label: "dev.opencfmoto.h264-encoder", qos: .userInteractive)
    private let frameLock = NSLock()
    private let log: LogHandler
    private var encoder: H264Encoder?
    private var timer: DispatchSourceTimer?
    private var bufferedFrames: [Data] = []
    private var initialKeyframe: Data?
    private var needsInitialKeyframe = true
    private var waitingConsumers: [(Data) -> Void] = []
    private var frameNumber: Int64 = 0

    init(log: @escaping LogHandler) {
        self.log = log
    }

    func start(width: Int, height: Int, framesPerSecond: Int) throws {
        stop()
        let safeWidth = max(16, width & ~15)
        let safeHeight = max(16, height & ~15)
        let safeFPS = min(max(framesPerSecond, 1), 30)

        var creationError: Error?
        encoderQueue.sync {
            do {
                let newEncoder = try H264Encoder(
                    width: safeWidth,
                    height: safeHeight,
                    framesPerSecond: safeFPS,
                    output: { [weak self] frame in self?.accept(frame) }
                )
                encoder = newEncoder
                frameNumber = 0
                frameLock.lock()
                initialKeyframe = nil
                needsInitialKeyframe = true
                frameLock.unlock()
                renderAndEncode(using: newEncoder, forceKeyframe: true)

                let newTimer = DispatchSource.makeTimerSource(queue: encoderQueue)
                newTimer.schedule(
                    deadline: .now() + .milliseconds(1000 / safeFPS),
                    repeating: .milliseconds(1000 / safeFPS),
                    leeway: .milliseconds(3)
                )
                newTimer.setEventHandler { [weak self, weak newEncoder] in
                    guard let self, let newEncoder else { return }
                    self.renderAndEncode(using: newEncoder, forceKeyframe: false)
                }
                timer = newTimer
                newTimer.resume()
            } catch {
                creationError = error
            }
        }
        if let creationError { throw creationError }
        log("H.264 encoder started: \(safeWidth)x\(safeHeight) @ \(safeFPS) fps")
    }

    func nextFrame(_ consumer: @escaping (Data) -> Void) {
        frameLock.lock()
        if needsInitialKeyframe, let initialKeyframe {
            needsInitialKeyframe = false
            self.initialKeyframe = nil
            bufferedFrames.removeAll(keepingCapacity: true)
            frameLock.unlock()
            consumer(initialKeyframe)
        } else if let newest = bufferedFrames.last {
            bufferedFrames.removeAll(keepingCapacity: true)
            frameLock.unlock()
            consumer(newest)
        } else {
            waitingConsumers.append(consumer)
            frameLock.unlock()
        }
    }

    func stop() {
        encoderQueue.sync {
            timer?.cancel()
            timer = nil
            encoder?.invalidate()
            encoder = nil
        }
        frameLock.lock()
        bufferedFrames.removeAll()
        initialKeyframe = nil
        needsInitialKeyframe = true
        waitingConsumers.removeAll()
        frameLock.unlock()
    }

    private func renderAndEncode(using encoder: H264Encoder, forceKeyframe: Bool) {
        do {
            let buffer = try encoder.makePixelBuffer()
            ProjectionFrameRenderer.draw(frame: frameNumber, into: buffer)
            try encoder.encode(
                buffer,
                frameNumber: frameNumber,
                forceKeyframe: forceKeyframe
            )
            frameNumber += 1
        } catch {
            log(error.localizedDescription)
        }
    }

    private func accept(_ frame: Data) {
        var consumer: ((Data) -> Void)?
        frameLock.lock()
        if needsInitialKeyframe, initialKeyframe == nil {
            initialKeyframe = frame
            if !waitingConsumers.isEmpty {
                consumer = waitingConsumers.removeFirst()
                needsInitialKeyframe = false
                initialKeyframe = nil
            }
        } else if !waitingConsumers.isEmpty {
            consumer = waitingConsumers.removeFirst()
        } else {
            bufferedFrames.append(frame)
            if bufferedFrames.count > 3 {
                bufferedFrames.removeFirst(bufferedFrames.count - 3)
            }
        }
        frameLock.unlock()
        consumer?(frame)
    }
}

private final class H264Encoder {
    private let width: Int
    private let height: Int
    private let framesPerSecond: Int32
    private let output: (Data) -> Void
    private var session: VTCompressionSession?

    init(width: Int, height: Int, framesPerSecond: Int, output: @escaping (Data) -> Void) throws {
        self.width = width
        self.height = height
        self.framesPerSecond = Int32(framesPerSecond)
        self.output = output

        let sourceAttributes = [
            kCVPixelBufferPixelFormatTypeKey: NSNumber(value: kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey: NSNumber(value: width),
            kCVPixelBufferHeightKey: NSNumber(value: height),
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ] as CFDictionary
        var createdSession: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: sourceAttributes,
            compressedDataAllocator: nil,
            outputCallback: h264CompressionOutputCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &createdSession
        )
        guard status == noErr, let createdSession else {
            throw H264VideoStreamError.compressionSession(status)
        }
        session = createdSession

        try set(kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        try set(kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Baseline_AutoLevel)
        try set(kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        try set(kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: framesPerSecond))
        try set(kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: framesPerSecond))
        try set(kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: 2_500_000))
        try set(
            kVTCompressionPropertyKey_DataRateLimits,
            value: [NSNumber(value: 312_500), NSNumber(value: 1)] as CFArray
        )

        let prepareStatus = VTCompressionSessionPrepareToEncodeFrames(createdSession)
        guard prepareStatus == noErr else {
            throw H264VideoStreamError.compressionSession(prepareStatus)
        }
    }

    func makePixelBuffer() throws -> CVPixelBuffer {
        guard let session, let pool = VTCompressionSessionGetPixelBufferPool(session) else {
            throw H264VideoStreamError.pixelBuffer
        }
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw H264VideoStreamError.pixelBuffer
        }
        return pixelBuffer
    }

    func encode(_ pixelBuffer: CVPixelBuffer, frameNumber: Int64, forceKeyframe: Bool) throws {
        guard let session else { throw H264VideoStreamError.compressionSession(-1) }
        let presentationTime = CMTime(value: frameNumber, timescale: framesPerSecond)
        let duration = CMTime(value: 1, timescale: framesPerSecond)
        let properties: CFDictionary? = forceKeyframe
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
            : nil
        var flags = VTEncodeInfoFlags()
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: presentationTime,
            duration: duration,
            frameProperties: properties,
            sourceFrameRefcon: nil,
            infoFlagsOut: &flags
        )
        guard status == noErr else { throw H264VideoStreamError.encode(status) }
    }

    func invalidate() {
        guard let session else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
        self.session = nil
    }

    fileprivate func receive(status: OSStatus, sampleBuffer: CMSampleBuffer?) {
        guard status == noErr,
              let sampleBuffer,
              CMSampleBufferDataIsReady(sampleBuffer),
              let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[CFString: Any]]
        let isKeyframe = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)

        var accessUnit = Data()
        if isKeyframe, let format = CMSampleBufferGetFormatDescription(sampleBuffer) {
            appendParameterSet(index: 0, from: format, to: &accessUnit)
            appendParameterSet(index: 1, from: format, to: &accessUnit)
        }

        let length = CMBlockBufferGetDataLength(blockBuffer)
        var avcc = Data(count: length)
        let copyStatus = avcc.withUnsafeMutableBytes { bytes -> OSStatus in
            guard let baseAddress = bytes.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(
                blockBuffer,
                atOffset: 0,
                dataLength: length,
                destination: baseAddress
            )
        }
        guard copyStatus == noErr else { return }

        var offset = 0
        while offset + 4 <= avcc.count {
            let nalLength = Int(avcc[offset]) << 24
                | Int(avcc[offset + 1]) << 16
                | Int(avcc[offset + 2]) << 8
                | Int(avcc[offset + 3])
            offset += 4
            guard nalLength > 0, offset + nalLength <= avcc.count else { return }
            accessUnit.append(contentsOf: [0, 0, 0, 1])
            accessUnit.append(avcc.subdata(in: offset..<(offset + nalLength)))
            offset += nalLength
        }

        if !accessUnit.isEmpty { output(accessUnit) }
    }

    private func set(_ key: CFString, value: CFTypeRef) throws {
        guard let session else { throw H264VideoStreamError.compressionSession(-1) }
        let status = VTSessionSetProperty(session, key: key, value: value)
        guard status == noErr else { throw H264VideoStreamError.compressionProperty(key, status) }
    }

    private func appendParameterSet(
        index: Int,
        from format: CMFormatDescription,
        to data: inout Data
    ) {
        var pointer: UnsafePointer<UInt8>?
        var size = 0
        var count = 0
        var headerLength: Int32 = 0
        let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format,
            parameterSetIndex: index,
            parameterSetPointerOut: &pointer,
            parameterSetSizeOut: &size,
            parameterSetCountOut: &count,
            nalUnitHeaderLengthOut: &headerLength
        )
        guard status == noErr, let pointer, size > 0 else { return }
        data.append(contentsOf: [0, 0, 0, 1])
        data.append(pointer, count: size)
    }
}

private func h264CompressionOutputCallback(
    outputCallbackRefCon: UnsafeMutableRawPointer?,
    sourceFrameRefCon: UnsafeMutableRawPointer?,
    status: OSStatus,
    infoFlags: VTEncodeInfoFlags,
    sampleBuffer: CMSampleBuffer?
) {
    guard let outputCallbackRefCon else { return }
    let encoder = Unmanaged<H264Encoder>.fromOpaque(outputCallbackRefCon).takeUnretainedValue()
    encoder.receive(status: status, sampleBuffer: sampleBuffer)
}

private enum ProjectionFrameRenderer {
    static func draw(frame: Int64, into pixelBuffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue
            | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let context = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return }

        context.setFillColor(CGColor(red: 0.025, green: 0.055, blue: 0.085, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let margin = CGFloat(width) * 0.045
        let panel = CGRect(
            x: margin,
            y: CGFloat(height) * 0.08,
            width: CGFloat(width) - margin * 2,
            height: CGFloat(height) * 0.84
        )
        context.setFillColor(CGColor(red: 0.055, green: 0.12, blue: 0.17, alpha: 1))
        context.fill(panel)

        let centerX = CGFloat(width) / 2
        context.beginPath()
        context.move(to: CGPoint(x: centerX - CGFloat(width) * 0.22, y: 0))
        context.addLine(to: CGPoint(x: centerX - CGFloat(width) * 0.075, y: CGFloat(height)))
        context.addLine(to: CGPoint(x: centerX + CGFloat(width) * 0.075, y: CGFloat(height)))
        context.addLine(to: CGPoint(x: centerX + CGFloat(width) * 0.22, y: 0))
        context.closePath()
        context.setFillColor(CGColor(red: 0.12, green: 0.15, blue: 0.17, alpha: 1))
        context.fillPath()

        context.setStrokeColor(CGColor(red: 0.2, green: 0.85, blue: 0.73, alpha: 1))
        context.setLineWidth(max(3, CGFloat(width) * 0.008))
        context.setLineDash(phase: CGFloat(frame % 40), lengths: [24, 18])
        context.move(to: CGPoint(x: centerX, y: 0))
        context.addLine(to: CGPoint(x: centerX, y: CGFloat(height)))
        context.strokePath()
        context.setLineDash(phase: 0, lengths: [])

        let progress = CGFloat(frame % 150) / 149
        let markerY = CGFloat(height) * (0.18 + progress * 0.64)
        let markerRadius = max(10, CGFloat(width) * 0.025)
        context.setFillColor(CGColor(red: 1, green: 0.48, blue: 0.12, alpha: 1))
        context.fillEllipse(in: CGRect(
            x: centerX - markerRadius,
            y: markerY - markerRadius,
            width: markerRadius * 2,
            height: markerRadius * 2
        ))

        let statusWidth = CGFloat(width) * 0.22
        context.setFillColor(CGColor(red: 0.12, green: 0.68, blue: 0.35, alpha: 1))
        context.fill(CGRect(
            x: margin * 1.5,
            y: CGFloat(height) * 0.78,
            width: statusWidth,
            height: max(8, CGFloat(height) * 0.035)
        ))
    }
}
