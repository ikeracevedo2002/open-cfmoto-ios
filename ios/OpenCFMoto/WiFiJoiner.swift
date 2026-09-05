import Foundation
import NetworkExtension

enum WiFiJoiner {
    static func join(_ payload: QRCodePayload) async throws {
        guard !payload.supportsPhoneHotspot else {
            throw JoinError.phoneHotspotUnsupported
        }
        guard payload.supportsAccessPoint, !payload.password.isEmpty else {
            throw JoinError.unsupportedTransport
        }

        let configuration = NEHotspotConfiguration(
            ssid: payload.ssid,
            passphrase: payload.password,
            isWEP: payload.authentication?.localizedCaseInsensitiveContains("wep") == true
        )
        configuration.joinOnce = false

        try await withCheckedThrowingContinuation { continuation in
            NEHotspotConfigurationManager.shared.apply(configuration) { error in
                if let error = error as? NEHotspotConfigurationError,
                   error.code == .alreadyAssociated {
                    continuation.resume()
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    enum JoinError: LocalizedError {
        case phoneHotspotUnsupported
        case unsupportedTransport

        var errorDescription: String? {
            switch self {
            case .phoneHotspotUnsupported:
                return "This dashboard expects the phone to host Wi-Fi; iOS does not expose a public API to configure Personal Hotspot."
            case .unsupportedTransport:
                return "This QR does not contain SoftAP credentials supported by the iOS build."
            }
        }
    }
}
