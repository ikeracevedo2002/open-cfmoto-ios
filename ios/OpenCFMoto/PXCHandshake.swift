import Foundation

struct PXCHandshake {
    private let phoneUUID = UUID().uuidString

    func responses(to frame: PXCFrame) -> [PXCFrame] {
        switch frame.command {
        case PXCFrame.channelCarControl, PXCFrame.channelCarData:
            return [PXCFrame(command: frame.command + 1, payload: Data())]
        case PXCFrame.heartbeat:
            return [PXCFrame(command: PXCFrame.heartbeatAck, payload: Data())]
        case PXCFrame.querySpeed:
            return [PXCFrame(command: PXCFrame.querySpeedReply, payload: Data())]
        case PXCFrame.timeSync:
            return [PXCFrame(command: PXCFrame.timeSyncAck, payload: frame.payload)]
        case PXCFrame.queryTime:
            return [PXCFrame(command: PXCFrame.queryTimeReply, payload: Data())]
        case PXCFrame.clientInfo:
            return [jsonFrame(command: PXCFrame.clientInfoReply, object: clientInfo())]
        case PXCFrame.checkSerial:
            let incoming = (try? JSONSerialization.jsonObject(with: frame.payload)) as? [String: Any]
            let serial = incoming?["sn"] as? String ?? ""
            return [
                PXCFrame(command: PXCFrame.checkSerialAck, payload: Data()),
                jsonFrame(command: PXCFrame.checkSerialResult, object: [
                    "isOk": true, "errCode": 0, "errMsg": "", "id": serial, "client_set": "easy_conn"
                ])
            ]
        case 0x0001_0780, 0x0001_03a0, 0x0001_0020, 0x0001_04a0:
            return [PXCFrame(command: frame.command + 1, payload: Data())]
        default:
            return []
        }
    }

    private func clientInfo() -> [String: Any] {
        // The control plane can be exercised now. RSA HUID signing is intentionally left blank
        // until it is validated against captures from a real iPhone-compatible dashboard.
        [
            "pxcVersion": "1.0.2",
            "phoneUUID": phoneUUID,
            "phoneBrand": "Apple",
            "phoneModel": "iPhone",
            "phoneOsVersion": ProcessInfo.processInfo.operatingSystemVersionString,
            "phoneOs": "iOS",
            "package": "com.cfmoto.cfmotointernational",
            "versionCode": 1,
            "token": 0,
            "pubkey": "",
            "encryptedHUID": "",
            "bluetoothName": "OpenCFMoto",
            "supportH264IFrame": true,
            "supportFunction": 0,
            "supportSyncCorrectTime": false,
            "appVersionFingerPrint": "opencfmoto-ios-native"
        ]
    }

    private func jsonFrame(command: UInt32, object: [String: Any]) -> PXCFrame {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return PXCFrame(command: command, payload: data)
    }
}
