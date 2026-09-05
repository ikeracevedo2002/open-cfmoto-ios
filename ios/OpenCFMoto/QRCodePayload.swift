import Foundation

struct QRCodePayload: Equatable, Sendable {
    let ssid: String
    let password: String
    let authentication: String?
    let macAddress: String?
    let name: String?
    let action: Int
    let modelID: String?
    let serialNumber: String?
    let channel: String?

    var supportsAccessPoint: Bool { action & 0x03 != 0 }
    var supportsPeerToPeer: Bool { action & 0x08 != 0 }
    var supportsPhoneHotspot: Bool { action & 0x80 != 0 }
    var displayName: String { name?.nilIfBlank ?? ssid }

    var transportDescription: String {
        if supportsPhoneHotspot { return "Phone hotspot" }
        if supportsPeerToPeer { return "Wi-Fi Direct" }
        return "SoftAP"
    }

    static func parse(_ rawValue: String) -> Self? {
        let raw = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        return parseCarbit(raw) ?? parseCarbitToken(raw) ?? parseMotoMorini(raw) ?? parseThinkerride(raw)
    }

    private static func parseCarbit(_ raw: String) -> Self? {
        guard let components = URLComponents(string: raw) else { return nil }
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map {
            ($0.name.lowercased(), $0.value ?? "")
        })
        let action = Int(query["action"] ?? "") ?? 0
        let mac = formatMAC(query["mac"]) ?? formatMAC(query["bm"])
        let ssid = query["ssid"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let password = query["pwd"] ?? ""
        let phoneHotspot = action & 0x80 != 0 || (ssid.isEmpty && mac != nil && query["bm"] != nil)
        guard phoneHotspot || (!ssid.isEmpty && !password.isEmpty) else { return nil }
        let fallbackSSID = "PHONE-HOTSPOT-\((mac ?? "").replacingOccurrences(of: ":", with: "").suffix(6))"
        return Self(
            ssid: ssid.isEmpty ? fallbackSSID : ssid,
            password: password,
            authentication: query["auth"],
            macAddress: mac,
            name: query["name"]?.nilIfBlank,
            action: phoneHotspot ? action | 0x80 : action,
            modelID: query["modelid"]?.nilIfBlank,
            serialNumber: query["sn"]?.nilIfBlank,
            channel: query["channel"]?.nilIfBlank
        )
    }

    private static func parseCarbitToken(_ raw: String) -> Self? {
        let pattern = #"(?i)^CARBIT([0-9A-F]{12})$"#
        guard let match = raw.firstMatch(pattern), let mac = formatMAC(match) else { return nil }
        return Self(ssid: "PHONE-HOTSPOT-\(match.suffix(6))", password: "", authentication: nil,
                    macAddress: mac, name: "Phone hotspot (\(mac.suffix(8)))", action: 128,
                    modelID: nil, serialNumber: nil, channel: nil)
    }

    private static func parseMotoMorini(_ raw: String) -> Self? {
        guard let wifi = raw.firstMatch(#"(?i)(?:^|[?&])Wifi=([^&#\s]+)"#),
              let wifiRange = raw.range(of: "Wifi=\(wifi)", options: .caseInsensitive) else { return nil }
        let tail = String(raw[wifiRange.upperBound...])
        guard tail.hasPrefix("#") else { return nil }
        let parts = tail.dropFirst().split(separator: "#", maxSplits: 1).map(String.init)
        guard let password = parts.first?.split(separator: "&").first.map(String.init), !password.isEmpty else { return nil }
        let machine = raw.firstMatch(#"(?i)MachineID=([^&#\s]+)"#)
        return Self(ssid: wifi, password: password, authentication: "wpa2-psk",
                    macAddress: formatMAC(parts.count > 1 ? String(parts[1].split(separator: "&")[0]) : machine),
                    name: wifi, action: 1, modelID: raw.firstMatch(#"(?i)ProductID=([^&#\s]+)"#),
                    serialNumber: machine, channel: nil)
    }

    private static func parseThinkerride(_ raw: String) -> Self? {
        guard raw.localizedCaseInsensitiveContains("thinkerride.com") || raw.uppercased().hasPrefix("CQKY_") else { return nil }
        let query = raw.contains("?") ? String(raw.split(separator: "?", maxSplits: 1)[1].split(separator: "#")[0]) : raw
        let values = query.split(separator: "&").map(String.init).filter { !$0.contains("=") }
        guard values.count >= 2 else { return nil }
        return Self(ssid: values[0].removingPercentEncoding ?? values[0],
                    password: values[1].removingPercentEncoding ?? values[1], authentication: "wpa2-psk",
                    macAddress: nil, name: values[0], action: 1, modelID: nil, serialNumber: nil, channel: nil)
    }

    private static func formatMAC(_ value: String?) -> String? {
        guard let value else { return nil }
        let hex = value.filter(\.isHexDigit)
        guard hex.count == 12 else { return value.contains(":") ? value : nil }
        return stride(from: 0, to: 12, by: 2).map {
            let start = hex.index(hex.startIndex, offsetBy: $0)
            let end = hex.index(start, offsetBy: 2)
            return String(hex[start..<end]).lowercased()
        }.joined(separator: ":")
    }
}

private extension String {
    var nilIfBlank: String? { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self }

    func firstMatch(_ pattern: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let result = expression.firstMatch(in: self, range: NSRange(startIndex..., in: self)),
              result.numberOfRanges > 1,
              let range = Range(result.range(at: 1), in: self) else { return nil }
        return String(self[range])
    }
}
