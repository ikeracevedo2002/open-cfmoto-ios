import Foundation

struct MediaRequest {
    let command: UInt16
    let token: UInt32
    let payload: Data
}

struct MediaCaptureConfiguration {
    let width: Int
    let height: Int
    let framesPerSecond: Int
    let encoder: UInt32
    let supportsExtendedProtocol: UInt8
}

struct EasyConnTouchEvent {
    enum Phase: String {
        case down
        case move
        case up
    }

    let phase: Phase
    let x: Int
    let y: Int
    let pointerID: Int
    let timestamp: UInt32
}

final class MediaStreamDecoder {
    private var buffer = Data()

    func append(_ data: Data) -> [MediaRequest] {
        buffer.append(data)
        var requests: [MediaRequest] = []
        while buffer.count >= 8 {
            let command = buffer.readUInt16LE(at: 0)
            let length = Int(buffer.readUInt16LE(at: 2))
            let token = buffer.readUInt32LE(at: 4)
            guard buffer.count >= 8 + length else { break }
            requests.append(MediaRequest(command: command, token: token,
                                         payload: buffer.subdata(in: 8..<(8 + length))))
            buffer.removeSubrange(0..<(8 + length))
        }
        return requests
    }
}

enum MediaProtocol {
    static func touchEvent(from request: MediaRequest) -> EasyConnTouchEvent? {
        guard request.command == 32, request.payload.count >= 8 else { return nil }
        let rawAction = request.payload.readUInt16LE(at: 0)
        let phase: EasyConnTouchEvent.Phase
        switch rawAction {
        case 2: phase = .down
        case 3: phase = .move
        case 1: phase = .up
        default: return nil
        }
        return EasyConnTouchEvent(
            phase: phase,
            x: Int(request.payload.readUInt16LE(at: 2)),
            y: Int(request.payload.readUInt16LE(at: 4)),
            pointerID: Int(request.payload.readUInt16LE(at: 6)),
            timestamp: request.payload.count >= 12 ? request.payload.readUInt32LE(at: 8) : 0
        )
    }

    static func captureConfiguration(from request: MediaRequest) -> MediaCaptureConfiguration {
        let requestedWidth = request.payload.count >= 2
            ? Int(request.payload.readUInt16LE(at: 0)) : 800
        let requestedHeight = request.payload.count >= 4
            ? Int(request.payload.readUInt16LE(at: 2)) : 480
        let requestedFPS = request.payload.count >= 8
            ? Int(request.payload.readUInt32LE(at: 4)) : 30
        let requestedEncoder = request.payload.count >= 12
            ? request.payload.readUInt32LE(at: 8) : 2
        return MediaCaptureConfiguration(
            width: max(16, (requestedWidth == 0 ? 800 : requestedWidth) & ~15),
            height: max(16, (requestedHeight == 0 ? 480 : requestedHeight) & ~15),
            framesPerSecond: min(max(requestedFPS == 0 ? 30 : requestedFPS, 1), 30),
            encoder: requestedEncoder == 0 ? 2 : requestedEncoder,
            supportsExtendedProtocol: request.payload.count > 29 ? request.payload[29] : 0
        )
    }

    static func response(to request: MediaRequest) -> Data? {
        switch request.command {
        case 16:
            let configuration = captureConfiguration(from: request)
            var payload = Data()
            payload.appendLittleEndian(configuration.encoder)
            payload.appendLittleEndian(UInt16(configuration.width))
            payload.appendLittleEndian(UInt16(configuration.height))
            payload.append(configuration.supportsExtendedProtocol)
            return frame(command: 17, payload: payload)
        case 48:
            var payload = Data()
            payload.appendLittleEndian(UInt32(3))
            payload.appendLittleEndian(UInt32(1))
            return frame(command: 49, payload: payload)
        case 64: return frame(command: 65)
        case 96: return frame(command: 97, payload: Data(#"{"state":0}"#.utf8))
        case 112: return frame(command: 113)
        case 128: return frame(command: 129)
        default: return nil
        }
    }

    private static func frame(command: UInt16, payload: Data = Data()) -> Data {
        var result = Data()
        result.appendLittleEndian(command)
        result.appendLittleEndian(UInt16(payload.count))
        result.appendLittleEndian(UInt32(0))
        result.append(payload)
        return result
    }
}
