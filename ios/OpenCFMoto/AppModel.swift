import Foundation

@MainActor
final class AppModel: ObservableObject {
    enum State: Equatable {
        case idle
        case awaitingManualWiFi(String)
        case discovering
        case handshaking
        case linked
        case failed(String)

        var title: String {
            switch self {
            case .idle: return "Ready"
            case .awaitingManualWiFi(let ssid): return "Connect to \(ssid)"
            case .discovering: return "Finding dashboard"
            case .handshaking: return "Negotiating EasyConn"
            case .linked: return "Dashboard linked"
            case .failed(let message): return message
            }
        }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var bike: QRCodePayload?
    @Published private(set) var logs: [String] = []
    @Published var isScannerPresented = false

    private var session: EasyConnSession?

    func accept(scanned value: String) {
        guard let payload = QRCodePayload.parse(value) else {
            fail("This is not a supported MotoPlay/EasyConn pairing QR")
            return
        }
        isScannerPresented = false
        bike = payload
        session?.stop()
        session = nil
        state = .awaitingManualWiFi(payload.ssid)
        log("Pairing QR accepted: \(payload.displayName)")
        log("Open Settings > Wi-Fi and join \(payload.ssid), then return to OpenCFMoto")
    }

    func reconnect() {
        guard bike != nil else { return }
        startSession()
    }

    func continueAfterManualWiFi() {
        startSession()
    }

    func stop() {
        session?.stop()
        session = nil
        state = .idle
        log("Stopped")
    }

    private func startSession() {
        session?.stop()
        state = .discovering
        log("Browsing _EasyConn._tcp on the current Wi-Fi network")

        let newSession = EasyConnSession { [weak self] event in
            Task { @MainActor in self?.consume(event) }
        }
        session = newSession
        newSession.start()
    }

    private func consume(_ event: EasyConnSession.Event) {
        switch event {
        case .log(let message): log(message)
        case .probing: state = .handshaking
        case .linked: state = .linked
        case .failed(let message): fail(message)
        }
    }

    private func fail(_ message: String) {
        state = .failed(message)
        log("Error: \(message)")
    }

    private func log(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        logs.append("\(formatter.string(from: Date()))  \(message)")
        if logs.count > 250 { logs.removeFirst(logs.count - 250) }
    }
}
