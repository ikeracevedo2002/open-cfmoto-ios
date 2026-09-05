import Combine
import UIKit

@MainActor
final class DisplayProtectionController: ObservableObject {
    @Published private(set) var isDisplayProtected = false
    @Published private(set) var isProximityFallbackEnabled = false
    @Published private(set) var isProximityCovered = false
    @Published private(set) var isVoiceOverRunning = UIAccessibility.isVoiceOverRunning

    private var savedBrightness: CGFloat?
    private var observers: [NSObjectProtocol] = []

    var shouldBlockTouches: Bool {
        isDisplayProtected || (isProximityFallbackEnabled && isProximityCovered)
    }

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: UIDevice.proximityStateDidChangeNotification,
            object: UIDevice.current,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.syncProximityState() }
        })
        observers.append(center.addObserver(
            forName: UIAccessibility.voiceOverStatusDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isVoiceOverRunning = UIAccessibility.isVoiceOverRunning
            }
        })
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func protectDisplay() {
        if savedBrightness == nil {
            savedBrightness = UIScreen.main.brightness
        }
        UIScreen.main.brightness = 0.01
        isDisplayProtected = true
        setProximityFallback(enabled: true)
        updateIdleTimer()
    }

    func restoreDisplay() {
        isDisplayProtected = false
        setProximityFallback(enabled: false)
        if let savedBrightness {
            UIScreen.main.brightness = savedBrightness
            self.savedBrightness = nil
        }
        updateIdleTimer()
    }

    func setProximityFallback(enabled: Bool) {
        UIDevice.current.isProximityMonitoringEnabled = enabled
        isProximityFallbackEnabled = UIDevice.current.isProximityMonitoringEnabled
        syncProximityState()
        updateIdleTimer()
    }

    private func syncProximityState() {
        isProximityCovered =
            UIDevice.current.isProximityMonitoringEnabled &&
            UIDevice.current.proximityState
    }

    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled =
            isDisplayProtected || isProximityFallbackEnabled
    }
}
