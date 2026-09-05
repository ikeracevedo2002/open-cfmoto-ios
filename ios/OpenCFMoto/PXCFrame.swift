import Foundation

struct PXCFrame: Equatable, Sendable {
    let command: UInt32
    let payload: Data

    static let channelCarControl: UInt32 = 0x0001_0000
    static let channelCarData: UInt32 = 0x0002_0000
    static let clientInfo: UInt32 = 0x0001_0010
    static let clientInfoReply: UInt32 = 0x0001_0011
    static let checkSerial: UInt32 = 0x0001_03e0
    static let checkSerialAck: UInt32 = 0x0001_03e1
    static let querySpeed: UInt32 = 0x0001_0690
    static let querySpeedReply: UInt32 = 0x0001_0691
    static let queryTime: UInt32 = 0x0001_0450
    static let queryTimeReply: UInt32 = 0x0001_0451
    static let timeSync: UInt32 = 0x0001_0600
    static let timeSyncAck: UInt32 = 0x0001_0601
    static let checkSerialResult: UInt32 = 0x0002_01c0
    static let heartbeat: UInt32 = 0x7000_0000
    static let heartbeatAck: UInt32 = 0x7000_0001
    static let discovery: UInt32 = 0x7000_0010
    static let discoveryAck: UInt32 = 0x7000_0011

    func encoded() -> Data {
        let length = UInt32(16 + payload.count)
        var data = Data()
        data.appendLittleEndian(command)
        data.appendLittleEndian(length)
        data.appendLittleEndian(command ^ length)
        data.appendLittleEndian(UInt32(0))
        data.append(payload)
        return data
    }
}

final class PXCStreamDecoder {
    enum DecodeError: Error { case invalidLength(UInt32), invalidMagic }
    private var buffer = Data()

    func append(_ data: Data) throws -> [PXCFrame] {
        buffer.append(data)
        var frames: [PXCFrame] = []

        while buffer.count >= 16 {
            let command = buffer.readUInt32LE(at: 0)
            let totalLength = buffer.readUInt32LE(at: 4)
            let magic = buffer.readUInt32LE(at: 8)
            guard totalLength >= 16, totalLength <= 16 * 1_024 * 1_024 else {
                throw DecodeError.invalidLength(totalLength)
            }
            guard command ^ totalLength == magic else { throw DecodeError.invalidMagic }
            guard buffer.count >= Int(totalLength) else { break }

            let payload = buffer.subdata(in: 16..<Int(totalLength))
            frames.append(PXCFrame(command: command, payload: payload))
            buffer.removeSubrange(0..<Int(totalLength))
        }
        return frames
    }
}

extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    func readUInt16LE(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }

    func readUInt32LE(at offset: Int) -> UInt32 {
        UInt32(self[offset]) |
        UInt32(self[offset + 1]) << 8 |
        UInt32(self[offset + 2]) << 16 |
        UInt32(self[offset + 3]) << 24
    }
}
