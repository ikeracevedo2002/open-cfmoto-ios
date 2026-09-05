import Foundation

protocol MotorcycleSession: AnyObject {
    func start()
    func stop()
}

extension EasyConnSession: MotorcycleSession {}

final class MockMotorcycleSession: MotorcycleSession {
    private let queue = DispatchQueue(label: "dev.opencfmoto.mock-motorcycle")
    private let emit: (EasyConnSession.Event) -> Void
    private var heartbeatTimer: DispatchSourceTimer?
    private var stopped = false

    init(emit: @escaping (EasyConnSession.Event) -> Void) {
        self.emit = emit
    }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopped = false
            self.emit(.log("MOCK dashboard powered on"))
            self.emit(.log("MOCK service published as _EasyConn._tcp"))

            self.schedule(after: 0.35) {
                self.emit(.probing)
                self.emit(.log("MOCK EasyConn service discovered"))
                self.emit(.log("PXC -> discoveryAck (accepted=true)"))
            }
            self.schedule(after: 0.70) {
                self.emit(.log("MOCK dashboard connected back on :10922"))
                self.emit(.log("PXC <- clientInfo"))
                self.emit(.log("PXC -> clientInfoReply"))
                self.emit(.log("PXC <- checkSerial"))
                self.emit(.log("PXC -> checkSerialResult (isOk=true)"))
            }
            self.schedule(after: 1.10) {
                self.emit(.log("MOCK dashboard connected back on :10920"))
                self.emit(.log("Media <- video negotiation (800x480 H.264)"))
                self.emit(.log("Media -> video negotiation accepted"))
            }
            self.schedule(after: 1.35) {
                self.emit(.log("MOCK dashboard connected back on :10921"))
                self.emit(.log("Media <- audio negotiation"))
                self.emit(.log("Media -> audio negotiation accepted"))
                self.emit(.linked)
                self.emit(.log("MOCK motorcycle is ready"))
                self.startHeartbeat()
            }
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopped = true
            self.heartbeatTimer?.cancel()
            self.heartbeatTimer = nil
        }
    }

    private func schedule(after delay: TimeInterval, action: @escaping () -> Void) {
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.stopped else { return }
            action()
        }
    }

    private func startHeartbeat() {
        heartbeatTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 5)
        timer.setEventHandler { [weak self] in
            guard let self, !self.stopped else { return }
            self.emit(.log("PXC <- heartbeat; PXC -> heartbeatAck"))
        }
        heartbeatTimer = timer
        timer.resume()
    }
}
