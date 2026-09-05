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
    @Published private(set) var isMockMode = false
    @Published var isScannerPresented = false

    private var session: MotorcycleSession?
    private var didStart = false

    var statusTitle: String {
        guard isMockMode else { return state.title }
        switch state {
        case .idle: return "Motorcycle simulator stopped"
        case .discovering: return "Starting motorcycle simulator"
        case .handshaking: return "Simulating EasyConn handshake"
        case .linked: return "Motorcycle simulator linked"
        case .failed(let message): return message
        case .awaitingManualWiFi: return "Motorcycle simulator"
        }
    }

    func start() {
        guard !didStart else { return }
        didStart = true
#if DEBUG
        startMockSession()
#else
        log("Ready to scan a motorcycle QR")
#endif
    }

    func accept(scanned value: String) {
        guard let payload = QRCodePayload.parse(value) else {
            fail("This is not a supported MotoPlay/EasyConn pairing QR")
            return
        }
        isScannerPresented = false
        isMockMode = false
        bike = payload
        session?.stop()
        session = nil
        state = .awaitingManualWiFi(payload.ssid)
        log("Pairing QR accepted: \(payload.displayName)")
        log("Open Settings > Wi-Fi and join \(payload.ssid), then return to OpenCFMoto")
    }

    func reconnect() {
        if isMockMode {
            startMockSession()
            return
        }
        guard bike != nil else { return }
        startRealSession()
    }

    func continueAfterManualWiFi() {
        startRealSession()
    }

    func useMockMotorcycle() {
        startMockSession()
    }

    func useRealMotorcycle() {
        session?.stop()
        session = nil
        isMockMode = false
        bike = nil
        state = .idle
        log("Real motorcycle mode selected")
    }

    func stop() {
        session?.stop()
        session = nil
        state = .idle
        log(isMockMode ? "Motorcycle simulator stopped" : "Stopped")
    }

    private func startRealSession() {
        session?.stop()
        isMockMode = false
        state = .discovering
        log("Browsing _EasyConn._tcp on the current Wi-Fi network")

        let newSession = EasyConnSession { [weak self] event in
            Task { @MainActor in self?.consume(event) }
        }
        session = newSession
        newSession.start()
    }

    private func startMockSession() {
        session?.stop()
        isMockMode = true
        bike = QRCodePayload(
            ssid: "OPENCFMOTO-MOCK",
            password: "",
            authentication: "simulated",
            macAddress: "02:00:00:00:10:92",
            name: "CFMOTO Dashboard Simulator",
            action: 1,
            modelID: "MOCK-800MT",
            serialNumber: "OPENCFMOTO-IOS-DEV",
            channel: "mock"
        )
        state = .discovering
        log("MOCK mode enabled; no QR, Wi-Fi or motorcycle is required")

        let newSession = MockMotorcycleSession { [weak self] event in
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
