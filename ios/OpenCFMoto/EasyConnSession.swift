import Foundation
import Network

final class EasyConnSession {
    enum Event {
        case log(String)
        case probing
        case linked
        case failed(String)
    }

    private let queue = DispatchQueue(label: "dev.opencfmoto.easyconn", qos: .userInitiated)
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let emit: (Event) -> Void
    private var browser: NWBrowser?
    private var listeners: [NWListener] = []
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private let handshake = PXCHandshake()
    private var didProbe = false
    private var stopped = false

    init(emit: @escaping (Event) -> Void) {
        self.emit = emit
        queue.setSpecific(key: queueKey, value: 1)
    }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                try [10920, 10921, 10922].forEach(self.startListener)
                self.startBrowser()
            } catch {
                self.emit(.failed("Could not open EasyConn ports: \(error.localizedDescription)"))
                self.stop()
            }
        }
    }

    func stop() {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            stopOnQueue()
        } else {
            queue.sync { stopOnQueue() }
        }
    }

    private func stopOnQueue() {
        stopped = true
        browser?.cancel()
        browser = nil
        listeners.forEach { $0.cancel() }
        listeners.removeAll()
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
    }

    private func startListener(port: UInt16) throws {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: endpointPort)
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.emit(.log("Listening on TCP :\(port)"))
            case .failed(let error): self?.emit(.failed("Listener :\(port) failed: \(error)"))
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection, port: port)
        }
        listener.start(queue: queue)
        listeners.append(listener)
    }

    private func startBrowser() {
        let browser = NWBrowser(for: .bonjour(type: "_EasyConn._tcp", domain: nil), using: .tcp)
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                self?.emit(.failed("Bonjour discovery failed: \(error.localizedDescription)"))
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self, !self.didProbe, let endpoint = results.first?.endpoint else { return }
            self.didProbe = true
            self.emit(.log("EasyConn service found: \(endpoint)"))
            self.probe(endpoint)
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    private func probe(_ endpoint: NWEndpoint) {
        emit(.probing)
        let connection = NWConnection(to: endpoint, using: .tcp)
        retain(connection)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready:
                let json = Data(#"{"phoneType":"iOS","packageName":"com.cfmoto.cfmotointernational"}"#.utf8)
                let frame = PXCFrame(command: PXCFrame.discovery, payload: json).encoded()
                connection.send(content: frame, completion: .contentProcessed { [weak self] error in
                    if let error { self?.emit(.failed("EasyConn probe failed: \(error.localizedDescription)")) }
                    else { self?.receiveProbeReply(connection) }
                })
            case .failed(let error):
                self.emit(.failed("Cannot reach EasyConn: \(error.localizedDescription)"))
            default: break
            }
        }
        connection.start(queue: queue)
    }

    private func receiveProbeReply(_ connection: NWConnection, decoder: PXCStreamDecoder = PXCStreamDecoder()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                do {
                    for frame in try decoder.append(data) where frame.command == PXCFrame.discoveryAck {
                        let text = String(data: frame.payload, encoding: .utf8) ?? ""
                        if text.localizedCaseInsensitiveContains("true") {
                            self.emit(.linked)
                            self.emit(.log("Dashboard accepted the EasyConn callback request"))
                        } else {
                            self.emit(.failed("Dashboard rejected the EasyConn probe"))
                        }
                    }
                } catch {
                    self.emit(.failed("Invalid EasyConn reply: \(error.localizedDescription)"))
                }
            }
            if !complete && error == nil { self.receiveProbeReply(connection, decoder: decoder) }
        }
    }

    private func accept(_ connection: NWConnection, port: UInt16) {
        retain(connection)
        emit(.log("Dashboard connected back on :\(port)"))
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready:
                if port == 10922 { self.receiveControl(connection) }
                else { self.receiveMedia(connection, decoder: MediaStreamDecoder()) }
            case .failed(let error): self.emit(.log("Connection :\(port) failed: \(error)"))
            case .cancelled: self.release(connection)
            default: break
            }
        }
        connection.start(queue: queue)
    }

    private func receiveControl(_ connection: NWConnection, decoder: PXCStreamDecoder = PXCStreamDecoder()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                do {
                    for frame in try decoder.append(data) {
                        self.emit(.log(String(format: "PXC <- 0x%08x (%d bytes)", frame.command, frame.payload.count)))
                        self.handshake.responses(to: frame).forEach { response in
                            self.send(response.encoded(), on: connection)
                        }
                    }
                } catch { self.emit(.failed("PXC framing error: \(error.localizedDescription)")) }
            }
            if !complete && error == nil { self.receiveControl(connection, decoder: decoder) }
        }
    }

    private func receiveMedia(_ connection: NWConnection, decoder: MediaStreamDecoder) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                for request in decoder.append(data) {
                    self.emit(.log("Media <- \(request.command) (\(request.payload.count) bytes)"))
                    if let response = MediaProtocol.response(to: request) { self.send(response, on: connection) }
                }
            }
            if !complete && error == nil { self.receiveMedia(connection, decoder: decoder) }
        }
    }

    private func send(_ data: Data, on connection: NWConnection) {
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error { self?.emit(.log("Send failed: \(error.localizedDescription)")) }
        })
    }

    private func retain(_ connection: NWConnection) { connections[ObjectIdentifier(connection)] = connection }
    private func release(_ connection: NWConnection) { connections.removeValue(forKey: ObjectIdentifier(connection)) }
}
