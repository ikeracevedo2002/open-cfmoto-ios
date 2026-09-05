import Foundation

struct MediaRequest {
    let command: UInt16
    let token: UInt32
    let payload: Data
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
    static func response(to request: MediaRequest) -> Data? {
        switch request.command {
        case 16:
            let width = request.payload.count >= 2 ? request.payload.readUInt16LE(at: 0) & 0xfff0 : 800
            let height = request.payload.count >= 4 ? request.payload.readUInt16LE(at: 2) & 0xfff0 : 480
            var payload = Data()
            payload.appendLittleEndian(UInt32(2))
            payload.appendLittleEndian(width)
            payload.appendLittleEndian(height)
            payload.append(request.payload.count > 29 ? request.payload[29] : 0)
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
